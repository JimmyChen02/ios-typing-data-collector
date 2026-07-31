// Google Apps Script — deploy as a Web App under your own Google account.
// Receives one session file at a time (as base64 JSON) from every
// FreeTypeRecorder install — screen.mov, face.mov, imu.csv,
// keystrokes.csv, seg_images/NNNN.jpg, seg_images/manifest.csv all arrive
// as separate requests, no zip — and saves each into:
//   Mobile Keyboard Data/<participant name>/<hand>/<session id>/<relativePath>
// `relativePath` may itself contain slashes (e.g. "seg_images/0001.jpg"),
// in which case the matching subfolder is created under the session
// folder. Runs as YOU, not the participant — no participant sign-in, no
// per-device setup. See ../docs/AUTOMATIC_DRIVE_UPLOAD.md for the
// deployment steps.

var SHARED_TOKEN = 'dafjadsfjUDHS12321tiffimu976';
var FOLDER_ID = '1_JaPMo0u0nW0dq69FP87Q4nkOgWBYPMC'; // Mobile Keyboard Data

function doPost(e) {
  // A session uploads dozens of files as separate requests, several of
  // which can execute concurrently. DriveApp.getFoldersByName() reads from
  // a search index that lags slightly behind creation, so two overlapping
  // executions can each decide a folder "doesn't exist yet" and both
  // create one — duplicate participant/session folders. The script-wide
  // lock serializes the whole find-or-create-and-write section so only
  // one execution touches folder creation at a time, regardless of how
  // many requests arrive together.
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(30000);
  } catch (lockError) {
    return jsonResponse({ ok: false, error: 'server busy, please retry' });
  }

  try {
    var payload = JSON.parse(e.postData.contents);

    if (payload.token !== SHARED_TOKEN) {
      return jsonResponse({ ok: false, error: 'unauthorized' });
    }
    // relativePath is the current field name; filename is accepted too so
    // an older-built app talking to a freshly redeployed script still works.
    var relativePath = payload.relativePath || payload.filename;
    if (!relativePath || !payload.data || !payload.sessionId) {
      return jsonResponse({ ok: false, error: 'missing relativePath, data, or sessionId' });
    }

    var rootFolder = DriveApp.getFolderById(FOLDER_ID);
    var participantName = (payload.participant || 'Unknown').toString().trim() || 'Unknown';
    var participantFolder = getOrCreateSubfolder(rootFolder, participantName);
    var hand = (payload.hand || '').toString().trim();
    var sessionParent = hand ? getOrCreateSubfolder(participantFolder, hand) : participantFolder;
    var sessionFolder = getOrCreateSubfolder(sessionParent, payload.sessionId);

    var pathParts = relativePath.split('/');
    var filename = pathParts.pop();
    var targetFolder = sessionFolder;
    for (var i = 0; i < pathParts.length; i++) {
      targetFolder = getOrCreateSubfolder(targetFolder, pathParts[i]);
    }

    var bytes = Utilities.base64Decode(payload.data);
    var blob = Utilities.newBlob(bytes, mimeTypeFor(filename), filename);
    targetFolder.createFile(blob);

    return jsonResponse({ ok: true });
  } catch (err) {
    return jsonResponse({ ok: false, error: err.toString() });
  } finally {
    lock.releaseLock();
  }
}

function mimeTypeFor(filename) {
  var lower = filename.toLowerCase();
  if (lower.indexOf('.mov') !== -1) return 'video/quicktime';
  if (lower.indexOf('.csv') !== -1) return 'text/csv';
  if (lower.indexOf('.jpg') !== -1 || lower.indexOf('.jpeg') !== -1) return 'image/jpeg';
  return 'application/octet-stream';
}

function getOrCreateSubfolder(parent, name) {
  var existing = parent.getFoldersByName(name);
  if (existing.hasNext()) {
    return existing.next();
  }
  return parent.createFolder(name);
}

function jsonResponse(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
