# PrairieTest Check-in

A proof-of-concept web app for exam proctors. Staff sign in with Google, then scan the barcode on a student's ID card with a phone (or laptop) camera, a USB barcode scanner, or by pasting the ID. The ID is shown in large text, looked up in a student roster (a Google Sheet or CSV), and a **Next** button moves on to the next student. Only staff whose email address is on an allowlist (another Google Sheet or CSV) can sign in.

There is no connection to PrairieTest or PrairieLearn yet. The reference pages for the PrairieTest Student ID App protocol are documented in the [second half of this README](#writing-a-student-id-app-for-prairietest).

## Running locally

Requires Ruby 3.2 or newer and Bundler.

```sh
bin/setup                   # bundle install and create .env from .env.example
bin/dev                     # start the server; PORT=8000 bin/dev to pick another port
```

The app listens on <http://localhost:8080>. Without `GOOGLE_CLIENT_ID` it shows a development sign-in form that accepts any email address instead of Google, and without `ALLOWLIST_SOURCE` or `ALLOWLIST_EMAILS` it lets anyone in, so it is usable straight away. Both fallbacks are refused in production (`RACK_ENV=production` fails to boot without them). Run the tests with:

```sh
bundle exec rake test
```

Browsers only allow camera access from HTTPS pages or from `localhost`, so open the app at `http://localhost:8080` on the same machine, or put an HTTPS tunnel (for example `cloudflared` or `ngrok`) in front of it to try it from a phone. Whatever public URL you use must also be registered as an OAuth redirect URI (see below).

## Configuration

All settings are environment variables. `.env.example` lists them; for local development copy it to `.env`.

| Variable | Required | Purpose |
| --- | --- | --- |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | yes | Google OAuth client credentials. |
| `GOOGLE_HOSTED_DOMAIN` | no | Google Workspace domain (e.g. `berkeley.edu`) to preselect in the account chooser. The allowlist is still enforced. |
| `SESSION_SECRET` | yes | Random string of at least 64 characters used to sign session cookies. Generate one with `ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'`. |
| `ALLOWLIST_SOURCE` | one of these | URL or file path of a CSV listing allowed email addresses. |
| `ALLOWLIST_EMAILS` | one of these | Comma-separated email addresses that are always allowed. |
| `ALLOWLIST_TTL_SECONDS` | no | How often the source is re-read. Default `300`. |
| `ROSTER_SOURCE` | no | URL or file path of a CSV student roster used to show who was scanned. |
| `ROSTER_TTL_SECONDS` | no | How often the roster is re-read. Default `300`. |
| `APP_BASE_URL` | no | Public URL of the app, e.g. `https://checkin.example.edu`. Only needed if OAuth redirects are generated with the wrong host or scheme behind a proxy. |
| `PORT`, `RACK_ENV` | no | Server port (default `8080`) and environment (`production` in Docker). |
| `PREVIEW_HOST` | no | Hostname of an embedded live preview (see below). Defaults to `AGENT_WEB_HOST` when Superconductor sets it. |
| `PREVIEW_FRAME_ANCESTORS` | no | Origins allowed to embed the app in preview mode. Default `https://superconductor.com https://*.superconductor.com`. |

### Google sign-in

1. In the [Google Cloud Console](https://console.cloud.google.com/apis/credentials), create a project (or pick one) and go to **APIs & Services → Credentials → Create credentials → OAuth client ID**, type **Web application**.
2. Under **Authorized redirect URIs** add `https://<your-domain>/auth/google/callback`, plus `http://localhost:8080/auth/google/callback` for development.
3. Configure the **OAuth consent screen**. For a Google Workspace organization such as `berkeley.edu`, choosing **Internal** limits sign-in to accounts in that organization. Otherwise choose **External** and add staff as test users while the app is in testing.
4. Copy the client ID and secret into `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`.

### Allowlist

A user is allowed if their (verified) Google email address appears in `ALLOWLIST_EMAILS` or in the CSV at `ALLOWLIST_SOURCE`. Matching is case-insensitive.

To use a Google Sheet, put the addresses in a column whose header contains the word "email" (other columns are ignored; if there is no such header, every cell that looks like an email address is used). Then either:

- **Publish it as CSV:** File → Share → Publish to web, choose the sheet and "Comma-separated values (.csv)", and copy the link into `ALLOWLIST_SOURCE`; or
- **Use the export URL:** share the sheet as "Anyone with the link can view" and set `ALLOWLIST_SOURCE` to `https://docs.google.com/spreadsheets/d/<SHEET_ID>/export?format=csv&gid=<GID>`.

Either way, anyone who has the link can read the list, so keep it to email addresses. Any other HTTPS URL returning CSV works too, as does a local file path (mount it into the container).

The list is fetched on demand and cached for `ALLOWLIST_TTL_SECONDS`. It is checked at sign-in and again on every page load, so removing someone takes effect within that interval. If a fetch fails, the last successfully loaded list is kept and a warning is logged.

### Student roster

If `ROSTER_SOURCE` is set, each scanned ID is looked up in that CSV and the student's name and email are shown under the ID. The roster is fetched the same way as the allowlist (Google Sheet published as CSV, any HTTPS URL, or a file path) and cached for `ROSTER_TTL_SECONDS`.

The first row must be a header. Column names are matched case-insensitively, and spaces, hyphens and underscores are interchangeable:

- The ID column is named **Student ID** or **SID** (so `student_id` and `Student-ID` also work).
- Displayed columns, when present: **Email** or **Email Address**; **Name** or **Full Name**; **First Name**; **Last Name**. If there is no name column, first and last name are combined.

Other columns are ignored. When a barcode starts with letters (for example a card-type prefix), the letters are stripped before the lookup and shown separately on the result screen. Without a roster the app still shows the scanned ID.

### Live preview in Superconductor

The app runs in Superconductor's live preview without any secrets. Configure the development environment (Project Settings → Development Environment → Manual Setup) as follows:

- **Build command:** `cd /workspace/pt-check-in && bundle install`
- **Startup command** (run in background): `cd /workspace/pt-check-in && PORT=8000 bin/dev`
- **HTTP service:** name `web`, port `8000`, primary. Keep the name `web` so Superconductor exports `AGENT_WEB_HOST`.

When `AGENT_WEB_HOST` (or `PREVIEW_HOST`) is set, the app switches to preview mode: it answers to that hostname, uses it for OAuth redirect URLs, replaces the `X-Frame-Options` header with a `Content-Security-Policy: frame-ancestors` rule allowing `PREVIEW_FRAME_ANCESTORS`, marks the session cookie `SameSite=None; Secure` so sign-in works inside the preview iframe, and accepts form posts from the preview origin. To try Google sign-in or a real allowlist/roster in a preview, add the corresponding variables as exported secrets in the development environment.

## Deploying with Docker

The `Dockerfile` builds a small production image running Puma on port 8080 as a non-root user, with a health check on `/health`.

```sh
docker build -t pt-check-in .
docker run --rm -p 8080:8080 --env-file .env -e RACK_ENV=production pt-check-in
# or
docker compose up --build
```

## Deploying with Dokploy

1. Push this repository to GitHub (or another Git host Dokploy can reach).
2. In Dokploy, create a project, then **Create Service → Application**. Pick the Git provider, repository and branch, and set **Build Type** to **Dockerfile** (path `Dockerfile`). Alternatively create a **Compose** service that uses `docker-compose.yml`.
3. On the **Environment** tab add the variables from `.env.example` with production values: `RACK_ENV=production`, `PORT=8080`, `SESSION_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `ALLOWLIST_SOURCE` and/or `ALLOWLIST_EMAILS`.
4. On the **Domains** tab add your hostname with container port `8080` and enable HTTPS (Let's Encrypt). HTTPS is required both for camera access and for Google OAuth.
5. Deploy, then add `https://<your-domain>/auth/google/callback` to the OAuth client's authorized redirect URIs.
6. If Google reports a `redirect_uri_mismatch` because the app generated an `http://` URL behind the proxy, set `APP_BASE_URL=https://<your-domain>` and redeploy.

## How scanning works

`/scan` accepts an ID from three sources, all leading to the same result screen:

- **Camera.** The page uses the browser's built-in [`BarcodeDetector`](https://developer.mozilla.org/docs/Web/API/BarcodeDetector) API when it is available and functional (Chrome on Android, Chrome and Safari on Apple platforms). Otherwise it loads the [ZXing](https://github.com/zxing-js/browser) library, vendored in `public/vendor/`, so no third-party requests are made at runtime. A value must be read twice in a row before it is accepted, which filters occasional misreads of 1D barcodes. Once a barcode is read the camera is stopped; **Next** restarts it.
- **USB barcode scanner.** Standard HID scanners act as a keyboard. The page listens for keystrokes anywhere on it, so a scan is picked up while the page is open, whether or not the camera is running. Scanners that send an Enter (or Tab) suffix are handled, and a fast burst of characters without a suffix is accepted once it stops.
- **Paste or type.** Pasting an ID, or typing one and pressing Enter, is accepted too. Only 5-20 letters and digits are accepted, so stray text is ignored with a message in the status line.

The result screen shows the ID in large text, any letter prefix separately, where the code came from, and the roster lookup result.

## Project layout

- `app.rb`, `config.ru`: the Sinatra application and routes.
- `bin/setup`, `bin/dev`: install dependencies and start the development server.
- `lib/csv_source.rb`, `lib/allowlist.rb`, `lib/roster.rb`: fetching and caching CSV data, the staff allowlist and the student roster.
- `views/`, `public/`: templates, stylesheet and the scanner script.
- `test/`: Minitest suite (`bundle exec rake test`).
- `Dockerfile`, `docker-compose.yml`, `config/puma.rb`: deployment.
- `read-id.html`, `show-photo.html`, `test-*.html`: reference pages for the PrairieTest Student ID App protocol, described below.

---

# Writing a Student ID App for PrairieTest

A Student ID App is a set of stand-alone web pages that interface between PrairieTest and university student ID services, including student ID card readers. These web pages should be served from a university web servers. There are two pages that make up the app:

- `read-id.html` interfaces to a card reader and university servers to translate a student ID card into a user ID for PrairieTest.

- `show-photo.html` receives a user ID from PrairieTest and displays the student's photo from university servers.

## Testing the Student ID App

There are two test pages provided:

- `test-read-id.html` embeds `read-id.html`. Open `test-read-id.html` in a local browser and enter a fake UID or UIN. You should see the status change to "Checking in..." and "Successfully checked in...".

- `test-show-photo.html` embeds `show-photo.html`. Open `test-show-photo.html` in a local browser and click one of the buttons to send the user ID to `show-photo.html`.

## Implementing your own Student ID App

1. Modify the starter files `read-id.html` and `show-photo.html` to interface to your university's identity servers. Test your modified pages as described in the section above.

2. Add authentication and authorization checks (see the "Authentication and Authorization" section below).

3. For production use, in both pages set `window.parentOrigin` to `https://www.prairietest.com` (or other appropriate value) and uncomment the line that checks `event.origin`.

4. Host these two pages on a university-managed web server with appropriate authentication and authorization.

5. Enter the URLs for the two pages into the PrairieTest institution configuration page.

## Purpose of the Student ID App

A Student ID App is an external web app that acts as an interface between PrairieTest and university-managed identity servers. A Student ID App is created and run by each university using PrairieTest, which has three key benefits:

1. Only the university-managed Student ID App has access to sensitive information such as student photos, the raw scan data from the student ID card, and other internal identifiers. The transfer of privacy-sensitive data to PrairieTest can be minimized to only the necessary unique student identifier.

2. Only the university-managed Student ID App connects to university identity databases, so PrairieTest does not need to have access to sensitive university data stores.

3. The Student ID App can be customized to work with the specific ID card system and format at each university. For example, to support mag-swipe, RFID readers, or optical bar-code scans, along with different formats for the data stored on the ID card.

## System architecture

Both PrairieTest and the Student ID App are web apps that are run by a proctor, on the proctor's computer. The proctor can authenticate separately to both apps, which then conduct all actions and data access using the proctor's credentials. The communication flow is:

![system_architecture](images/system_diagram.png)

Note that:

- Only the PrairieTest App communicates with `prairietest.com` servers, and only the Student ID App communicates with university servers.
- The Student ID App runs in a browser on the proctor's computer, which can be controlled by the university to implement additional security measures such as IP restrictions, 2-factor authentication, and physical security.

## Message format

Messages between the PrairieTest App and Student ID App are sent using the [`postMessage()`](https://developer.mozilla.org/en-US/docs/Web/API/Window/postMessage) browser API. The message payload is an object with properties:

- `tag`: A string specifying the message type. This property is mandatory.
- `secret`: A string holding a shared secret. This property is mandatory for all messages sent from the Student ID App to the PrairieTest App. The secret is created by the PrairieTest App and sent to the Student ID App with the first `init` message. Any messages sent to the PrairieTest App without the secret will be silently ignored.
- Other fields: Data values specific to the message type.

## Message types

The valid message types are:

- `init` message:

  **Tag:** `init`

  **Direction:** PrairieTest App -> Student ID App

  **Format:** `{tag: "init", secret: "xxx"}`

  **Description:** Initialize the app and store the `secret` for later communication.

- `initialized` message:

  **Tag:** `initialized`

  **Direction:** Student ID App -> PrairieTest App

  **Format:** `{tag: "initialized", secret: "xxx"}`

  **Description:** Report that initialization is complete and that the page is ready to accept card reads. The `secret` must be the same as that sent in the original `init` message.

- `read-id` message:

  **Tag:** `read-id`

  **Direction:** `read-id.html` -> PrairieTest App

  **Format:** `{tag: "read-id", secret: "xxx", uid: "user@example.com", uin: "NNNN"}`

  **Description:** Report a student ID card read for the user with the given `uid` and `uin`. Only one of `uid` and `uin` must be specified and if both are provided then only `uin` will be used. The `secret` must be the same as that sent in the original `init` message.

- `show-photo` message:

  **Tag:** `show-photo`

  **Direction:** PrairieTest App -> `show-photo.html`

  **Format:** `{tag: "show-photo", uid: "user@example.com", uin: "NNNN"}`

  **Description:** Display the photo of the student identified by the given `uid` and `uin`.

## Authentication and Authorization

It is recommended that `read-id.html` and `show-photo.html` should independently authenticate and authorize the proctor, for example by hosting these pages on a Shibboleth-protected server.
