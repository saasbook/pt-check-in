// Barcode scanner for student ID cards.
//
// Three input paths lead to the same result screen:
//
// 1. The phone (or computer) camera. Uses the browser's native BarcodeDetector
//    API when it is available and functional (Chrome on Android, Chrome/Safari
//    on Apple platforms). Otherwise it falls back to the ZXing library
//    (vendored in public/vendor), loaded on demand.
// 2. A USB barcode scanner. These act as keyboards ("keyboard wedge"), typing
//    the code very quickly and usually finishing with Enter.
// 3. Pasting or typing an ID and pressing Enter.
//
// Once a code is accepted, all letters are stripped (faculty and staff cards
// add letters to the number), the remaining ID is looked up in the roster
// via /api/lookup, and, when embedded in PrairieTest, reported with a
// "read-id" postMessage.

var ZXING_URL = "/vendor/zxing-browser-0.1.5.min.js";

// Prefer the rear ("environment") camera on phones; on a laptop this
// falls back to whatever camera exists.
var CAMERA_CONSTRAINTS = {
    audio: false,
    video: {
        facingMode: {ideal: "environment"},
        width: {ideal: 1280},
        height: {ideal: 720},
    },
};

// Number of consecutive identical camera reads required before a value is
// accepted. This filters out occasional misreads of 1D barcodes.
var REQUIRED_CONSECUTIVE_READS = 2;

// What typed or pasted text is accepted as an ID: letters and digits, 5-20 characters.
var TYPED_CODE_RE = /^[A-Za-z0-9]{5,20}$/;
// What must remain after the letters are removed.
var ID_RE = /^[0-9]{4,20}$/;

// Keystrokes closer together than this come from a scanner, not a person.
var WEDGE_FAST_GAP_MS = 75;
// A fast burst with no Enter suffix is accepted this long after the last key.
var WEDGE_SETTLE_MS = 150;
// Typed characters are forgotten after a pause this long without Enter.
var WEDGE_IDLE_MS = 3000;

var ready = function(callback) {
    if (document.readyState != "loading") callback();
    else document.addEventListener("DOMContentLoaded", callback);
};

function setStatus(text, isError) {
    var el = document.getElementById("status");
    el.textContent = text;
    el.classList.toggle("error", !!isError);
}

// Splits a code into [letters, id]: every letter and all whitespace are removed
// from the ID, e.g. "AB 3034567890" -> ["AB", "3034567890"]. Mirrors Roster.split_code.
function splitCode(code) {
    var text = String(code).trim();
    return [(text.match(/[A-Za-z]+/g) || []).join(""), text.replace(/[A-Za-z\s]+/g, "")];
}

// --- PrairieTest bridge -----------------------------------------------------
// PrairieTest embeds this page in an iframe and sends {tag: "init", secret}.
// We answer {tag: "initialized", secret} and later report each scan with
// {tag: "read-id", secret, uin} (or uid). See README, "Message types".
var pt = {
    origin: null,        // origin we accept messages from ("*" = any, local testing only)
    idField: "uin",      // "uin": send the scanned number; "uid": send the roster email
    secret: null,
    replyOrigin: null,
    connected: false,
};

function setPtStatus(text, connected) {
    var el = document.getElementById("pt-status");
    el.textContent = text;
    el.classList.toggle("connected", !!connected);
}

function onPrairieTestMessage(event) {
    if (!event.data || event.data.tag !== "init") return;
    if (pt.origin !== "*" && event.origin !== pt.origin) {
        console.warn("Ignoring init message from unexpected origin", event.origin);
        return;
    }
    pt.secret = event.data.secret;
    pt.replyOrigin = pt.origin === "*" ? event.origin : pt.origin;
    pt.connected = true;
    event.source.postMessage({tag: "initialized", secret: pt.secret}, pt.replyOrigin);
    setPtStatus("connected", true);
}

// Reports a scan to PrairieTest. Returns a message describing what happened.
function sendToPrairieTest(id, student) {
    if (!pt.connected) return null;
    var message = {tag: "read-id", secret: pt.secret};
    if (pt.idField === "uid") {
        if (!student || !student.email) return "Not sent to PrairieTest: no email found in the roster for this ID.";
        message.uid = student.email;
    } else {
        if (!id) return "Not sent to PrairieTest: no ID number in the scan.";
        message.uin = id;
    }
    window.parent.postMessage(message, pt.replyOrigin);
    return "Sent to PrairieTest as " + (message.uin ? "UIN " + message.uin : "UID " + message.uid) + ".";
}

function showPtSent(text) {
    var el = document.getElementById("pt-sent");
    el.hidden = !text;
    el.textContent = text || "";
    el.classList.toggle("problem", !!text && text.indexOf("Not sent") === 0);
}

// Loads the ZXing UMD bundle once and resolves with the ZXingBrowser global.
var zxingPromise = null;
function loadZXing() {
    if (window.ZXingBrowser) return Promise.resolve(window.ZXingBrowser);
    if (zxingPromise) return zxingPromise;
    zxingPromise = new Promise((resolve, reject) => {
        var script = document.createElement("script");
        script.src = ZXING_URL;
        script.onload = () => {
            if (window.ZXingBrowser) resolve(window.ZXingBrowser);
            else reject(new Error("ZXing library loaded but ZXingBrowser is not defined"));
        };
        script.onerror = () => {
            zxingPromise = null;
            reject(new Error("Failed to load the ZXing barcode library from " + ZXING_URL));
        };
        document.head.appendChild(script);
    });
    return zxingPromise;
}

// Returns a native BarcodeDetector if the browser has a working one, else null.
// Some browsers expose the class but support no formats on the current platform.
async function getNativeDetector() {
    if (!("BarcodeDetector" in window)) return null;
    try {
        var formats = await window.BarcodeDetector.getSupportedFormats();
        if (!formats || formats.length == 0) return null;
        return new window.BarcodeDetector({formats: formats});
    } catch (err) {
        console.warn("Native BarcodeDetector unavailable:", err);
        return null;
    }
}

// Describes a start-up failure for display to the proctor.
function describeError(err) {
    if (!window.isSecureContext) {
        return "Camera access requires HTTPS (or localhost). This page was loaded over an insecure connection.";
    }
    switch (err && err.name) {
    case "NotAllowedError":
    case "SecurityError":
        return "Camera permission was denied. Allow camera access for this site and press Retry.";
    case "NotFoundError":
    case "OverconstrainedError":
        return "No camera was found on this device.";
    case "NotReadableError":
    case "AbortError":
        return "The camera is in use by another application or could not be started.";
    default:
        return err && err.message ? err.message : String(err);
    }
}

// Camera scanner state.
var stream = null;          // active MediaStream from the camera
var stopDetection = null;   // function that halts the current detection loop
var lastValue = null;       // most recently decoded value
var consecutiveReads = 0;   // how many times in a row lastValue was read
var lookupSequence = 0;     // guards against out-of-order lookup responses

function showScanner() {
    document.getElementById("scanner").hidden = false;
    document.getElementById("result").hidden = true;
}

function showResult(code, sourceLabel) {
    var parts = splitCode(code);
    var letters = parts[0], id = parts[1];
    var lettersEl = document.getElementById("barcode-letters");
    lettersEl.textContent = letters ? "Letters removed: " + letters : "";
    lettersEl.hidden = !letters;
    document.getElementById("barcode-id").textContent = id || code;
    document.getElementById("barcode-source").textContent = sourceLabel;
    showPtSent(null);
    document.getElementById("scanner").hidden = true;
    document.getElementById("result").hidden = false;
    document.getElementById("next").focus();
    lookupStudent(code);
}

// Renders a list of [className, text] lines into the student box.
function renderStudent(lines) {
    var box = document.getElementById("student");
    box.textContent = "";
    lines.forEach((line) => {
        var div = document.createElement("div");
        div.className = line[0];
        div.textContent = line[1];
        box.appendChild(div);
    });
}

async function lookupStudent(code) {
    var sequence = ++lookupSequence;
    renderStudent([["muted", "Looking up student..."]]);
    try {
        var response = await fetch("/api/lookup?code=" + encodeURIComponent(code), {
            credentials: "same-origin",
            headers: {"Accept": "application/json"},
        });
        if (response.status == 401 || response.status == 403) {
            window.location.reload(); // session ended; the page will redirect to login
            return;
        }
        if (!response.ok) throw new Error("Lookup failed (HTTP " + response.status + ")");
        var data = await response.json();
        if (sequence != lookupSequence) return; // a newer scan replaced this one

        showPtSent(sendToPrairieTest(data.id, data.student));
        if (data.student) {
            var lines = [];
            if (data.student.name) lines.push(["name", data.student.name]);
            if (data.student.email) lines.push(["email", data.student.email]);
            if (lines.length == 0) lines.push(["muted", "Found in roster (no name or email columns)"]);
            renderStudent(lines);
        } else if (!data.roster.configured) {
            renderStudent([["muted", "No roster configured, so the ID was not looked up."]]);
        } else if (data.roster.error) {
            renderStudent([["not-found", "Roster unavailable"], ["muted", data.roster.error]]);
        } else {
            renderStudent([["not-found", "Not found in roster"]]);
        }
    } catch (err) {
        if (sequence != lookupSequence) return;
        console.error(err);
        renderStudent([["not-found", "Lookup failed"], ["muted", err.message]]);
        // The number itself is still known, so PrairieTest can be told in uin mode.
        showPtSent(sendToPrairieTest(splitCode(code)[1], null));
    }
}

async function stopScanning() {
    if (stopDetection) {
        var stop = stopDetection;
        stopDetection = null;
        try { await stop(); } catch (err) { console.warn("Error stopping detection:", err); }
    }
    if (stream) {
        stream.getTracks().forEach((track) => track.stop());
        stream = null;
    }
    var video = document.getElementById("video");
    video.pause();
    video.srcObject = null;
}

// Accepts a code from any input path: stops the camera and shows the result.
function acceptCode(code, sourceLabel) {
    stopScanning();
    if (navigator.vibrate) navigator.vibrate(100);
    setStatus("Barcode read. Press Next to scan another student.");
    showResult(code, sourceLabel);
}

// Called for every camera decode. Accepts a value once it has been read
// REQUIRED_CONSECUTIVE_READS times in a row.
function handleRead(value, format) {
    if (value === lastValue) {
        consecutiveReads++;
    } else {
        lastValue = value;
        consecutiveReads = 1;
    }
    if (consecutiveReads < REQUIRED_CONSECUTIVE_READS) return;

    // Ignore any further callbacks that arrive while we shut the camera down.
    if (!stopDetection) return;
    acceptCode(value, "Camera, format " + format);
}

// Detection loop using the native BarcodeDetector API.
function detectWithNative(detector, video) {
    var running = true;
    var pending = false;
    var timer = null;
    async function tick() {
        if (!running) return;
        if (!pending && video.readyState >= 2) { // HAVE_CURRENT_DATA
            pending = true;
            try {
                var barcodes = await detector.detect(video);
                if (running && barcodes.length > 0) {
                    handleRead(barcodes[0].rawValue, barcodes[0].format);
                }
            } catch (err) {
                console.warn("detect() failed:", err);
            }
            pending = false;
        }
        if (running) timer = setTimeout(tick, 100);
    }
    tick();
    return () => {
        running = false;
        clearTimeout(timer);
    };
}

// Detection loop using ZXing. ZXing manages the video element itself,
// decoding frames from the stream we already opened.
async function detectWithZXing(ZXingBrowser, mediaStream, video) {
    var reader = new ZXingBrowser.BrowserMultiFormatReader(undefined, {
        delayBetweenScanAttempts: 100,
        delayBetweenScanSuccess: 300,
    });
    var controls = await reader.decodeFromStream(mediaStream, video, (result, err) => {
        // ZXing reports a NotFoundException on every frame without a
        // barcode, so only errors of other types are worth logging.
        if (result) {
            handleRead(result.getText(), ZXingBrowser.BarcodeFormat[result.getBarcodeFormat()]);
        } else if (err && err.name && err.name != "NotFoundException") {
            console.warn("ZXing decode error:", err);
        }
    });
    return () => controls.stop();
}

async function startScanning() {
    await stopScanning();
    lastValue = null;
    consecutiveReads = 0;
    showScanner();
    document.getElementById("retry").hidden = true;

    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        setStatus("This browser does not support camera access. A USB scanner or pasted ID still works.", true);
        document.getElementById("retry").hidden = false;
        return;
    }

    var video = document.getElementById("video");
    try {
        setStatus("Looking for a barcode scanner...");
        var detector = await getNativeDetector();
        var ZXingBrowser = null;
        if (!detector) {
            setStatus("Loading barcode library...");
            ZXingBrowser = await loadZXing();
        }

        setStatus("Starting camera...");
        stream = await navigator.mediaDevices.getUserMedia(CAMERA_CONSTRAINTS);

        if (detector) {
            video.srcObject = stream;
            await video.play();
            stopDetection = detectWithNative(detector, video);
        } else {
            stopDetection = await detectWithZXing(ZXingBrowser, stream, video);
        }
        setStatus("Point the camera at a barcode.");
    } catch (err) {
        console.error(err);
        await stopScanning();
        setStatus(describeError(err), true);
        document.getElementById("retry").hidden = false;
    }
}

// Keyboard wedge: collects keystrokes from a USB scanner (or a person typing)
// anywhere on the page and accepts them as a code.
var wedgeBuffer = "";
var wedgeLastKeyAt = 0;
var wedgeFast = true;      // every gap in the current buffer was scanner-fast
var wedgeSettleTimer = null;

function isTextField(el) {
    return el && (el.tagName == "INPUT" || el.tagName == "TEXTAREA" || el.isContentEditable);
}

function resetWedge() {
    wedgeBuffer = "";
    wedgeFast = true;
    clearTimeout(wedgeSettleTimer);
    wedgeSettleTimer = null;
}

// True if typed/pasted text looks like an ID once letters are removed.
function acceptableCode(text) {
    return TYPED_CODE_RE.test(text) && ID_RE.test(splitCode(text)[1]);
}

function finishWedge(sourceLabel) {
    var code = wedgeBuffer;
    resetWedge();
    if (acceptableCode(code)) {
        acceptCode(code, sourceLabel);
    } else if (code) {
        setStatus("Ignored \"" + code + "\": IDs are 5-20 letters and digits with at least 4 digits.", true);
    }
}

function onManualSubmit(event) {
    event.preventDefault();
    var input = document.getElementById("manual-id");
    var code = input.value.trim();
    if (!acceptableCode(code)) {
        setStatus("\"" + code + "\" is not a valid ID: 5-20 letters and digits with at least 4 digits.", true);
        return;
    }
    input.value = "";
    acceptCode(code, "Typed");
}

function onKeyDown(event) {
    if (event.ctrlKey || event.metaKey || event.altKey || isTextField(event.target)) return;

    var now = performance.now();
    var gap = now - wedgeLastKeyAt;
    if (gap > WEDGE_IDLE_MS) resetWedge();

    if (event.key == "Enter" || event.key == "Tab") {
        if (!wedgeBuffer) return;
        event.preventDefault(); // don't let Enter activate the focused Next button
        finishWedge(wedgeFast ? "USB scanner" : "Typed");
        return;
    }
    if (event.key.length != 1) return; // ignore Shift, arrows, function keys, etc.

    if (wedgeBuffer && gap > WEDGE_FAST_GAP_MS) wedgeFast = false;
    wedgeBuffer += event.key;
    wedgeLastKeyAt = now;

    // Scanners configured without an Enter suffix: accept a fast burst once it stops.
    clearTimeout(wedgeSettleTimer);
    if (wedgeFast && wedgeBuffer.length >= 5) {
        wedgeSettleTimer = setTimeout(() => {
            if (wedgeFast && acceptableCode(wedgeBuffer)) finishWedge("USB scanner");
        }, WEDGE_SETTLE_MS);
    }
}

function onPaste(event) {
    if (isTextField(event.target)) return;
    var text = (event.clipboardData || window.clipboardData).getData("text").trim();
    if (!acceptableCode(text)) {
        setStatus("Ignored pasted text: IDs are 5-20 letters and digits with at least 4 digits.", true);
        return;
    }
    event.preventDefault();
    resetWedge();
    acceptCode(text, "Pasted");
}

ready(() => {
    var section = document.getElementById("scan");
    pt.origin = section.dataset.ptOrigin || "*";
    pt.idField = section.dataset.ptIdField || "uin";
    window.addEventListener("message", onPrairieTestMessage);
    setPtStatus(window.parent === window ? "not embedded" : "not connected", false);

    document.getElementById("manual").addEventListener("submit", onManualSubmit);
    document.getElementById("next").addEventListener("click", startScanning);
    document.getElementById("retry").addEventListener("click", startScanning);
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("paste", onPaste);
    startScanning();
});
