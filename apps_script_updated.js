// --- APP SCRIPT ---

/**************************************
 * ABLE HOME INVENTORY – APP SCRIPT
 * Bound to: Able Home Accessibility - App Database
 **************************************/

const SHEET_STAIRLIFTS      = 'Inventory_Stairlifts';
const SHEET_RAMPS           = 'Inventory_Ramps';
const SHEET_CHANGES         = 'Inventory_Changes';
const SHEET_LIFTS_MASTER    = 'Lifts_Master';
const SHEET_LIFT_HISTORY    = 'Lift_History';
const SHEET_LIFT_SERVICE    = 'Lifts_Service';
const SHEET_PICKUP_LIST     = 'PickupList';
const SHEET_PREP_CHECKLISTS = 'Prep_Checklists';

/**
 * Main entry points – ALWAYS return JSON, never HTML.
 */
function doGet(e) {
  const params = e && e.parameter ? e.parameter : {};
  return handleRequest(params);
}

function doPost(e) {
  let body = {};
  if (e && e.postData && e.postData.contents) {
    try {
      body = JSON.parse(e.postData.contents);
    } catch (err) {
      // If body isn't JSON, ignore and just use query params
    }
  }
  const params = Object.assign({}, e.parameter || {}, body || {});
  return handleRequest(params);
}

function handleRequest(params) {
  const action = (params.action || '').toString();

  try {
    let result;
    switch (action) {
      case 'get_inventory':
        result = apiGetInventory();
        break;

      case 'get_changes':
        result = apiGetChanges(params);
        break;

      case 'get_lifts':
        result = apiGetLifts();
        break;

      case 'get_lift_history':
        result = apiGetLiftHistory(params);
        break;

      case 'get_lift_service':
        result = apiGetLiftService(params);
        break;

      case 'full_check':
        result = apiFullCheck(params);
        break;

      case 'job_adjustment':
        result = apiJobAdjustment(params);
        break;

      case 'upsert_lift':
        result = apiUpsertLift(params);
        break;

      case 'add_lift_service':
        result = apiAddLiftService(params);
        break;

      case 'delete_lift':
        result = apiDeleteLift(params);
        break;

      // === Pickup List API ===
      case 'get_pickup_list':
        result = apiGetPickupList();
        break;

      case 'add_pickup_item':
        result = apiAddPickupItem(params);
        break;

      case 'update_pickup_item':
        result = apiUpdatePickupItem(params);
        break;

      // === Prep Checklist API ===
      case 'get_prep_checklists':
        result = apiGetPrepChecklists(params);
        break;

      case 'save_prep_checklist':
        result = apiSavePrepChecklist(params);
        break;

      case 'get_prep_checklist_template':
        result = apiGetPrepChecklistTemplate(params);
        break;

      default:
        result = {
          status: 'error',
          message: 'Unknown action: ' + action
        };
    }

    return ContentService
      .createTextOutput(JSON.stringify(result))
      .setMimeType(ContentService.MimeType.JSON);

  } catch (err) {
    const errorResult = {
      status: 'error',
      message: err && err.message ? err.message : String(err)
    };
    return ContentService
      .createTextOutput(JSON.stringify(errorResult))
      .setMimeType(ContentService.MimeType.JSON);
  }
}

/**************************************
 * HELPERS
 **************************************/

function getSs() {
  return SpreadsheetApp.getActiveSpreadsheet();
}

function toNumber(v) {
  if (v === '' || v === null || v === undefined) return 0;
  const n = Number(v);
  return isNaN(n) ? 0 : n;
}

/**************************************
 * GET INVENTORY
 **************************************/

function apiGetInventory() {
  const ss = getSs();

  // ===== Stairlifts =====
  const stairSheet = ss.getSheetByName(SHEET_STAIRLIFTS);
  const stairValues = stairSheet.getDataRange().getValues();
  const stairHeader = stairValues[0];
  const stairDataRows = stairValues.slice(1);

  const stairlifts = stairDataRows
    .filter(r => String(r[1] || '').trim() !== '') // item_id
    .map(r => ({
      item_id:       String(r[0] || ''),
      brand:         String(r[1] || ''),
      series:        String(r[2] || ''),
      orientation:   String(r[3] || ''),
      fold_type:     String(r[4] || ''),
      condition:     String(r[5] || ''),
      min_qty:       toNumber(r[6]),
      current_qty:   toNumber(r[7]),
      active:        String(r[8] || 'Y'),
      notes:         String(r[9] || '')
    }));

  // ===== Ramps =====
  const rampSheet = ss.getSheetByName(SHEET_RAMPS);
  const rampValues = rampSheet.getDataRange().getValues();
  const rampDataRows = rampValues.slice(1);

  const ramps = rampDataRows
    .filter(r => r[0] !== '' && r[0] !== null) // item_id
    .map(r => ({
      item_id:       String(r[0] || ''),
      brand:         String(r[1] || ''),
      size:          String(r[2] || ''),
      condition:     String(r[3] || ''),
      current_qty:   toNumber(r[4]),
      min_qty:       toNumber(r[5]),
      active:        'Y',           // sheet doesn't have this; assume active
      notes:         ''             // sheet doesn't have this
    }));

  return {
    status: 'ok',
    stairlifts: stairlifts,
    ramps: ramps
  };
}

/**************************************
 * INVENTORY CHANGE LOG
 **************************************/

function apiGetChanges(params) {
  const limit = params && params.limit ? Number(params.limit) : 200;

  const ss = getSs();
  const sheet = ss.getSheetByName(SHEET_CHANGES);
  const values = sheet.getDataRange().getValues();
  const rows = values.slice(1); // skip header

  // Take most recent `limit` rows from bottom
  const recent = rows.slice(Math.max(0, rows.length - limit));

  const changes = recent.map(r => ({
    // Expected sheet layout:
    // 0: timestamp
    // 1: user_email
    // 2: user_name
    // 3: change_type
    // 4: item_id
    // 5: brand
    // 6: series_or_size
    // 7: orientation
    // 8: condition
    // 9: old_qty
    // 10: new_qty
    // 11: delta
    // 12: job_ref
    timestamp:       r[0] ? new Date(r[0]) : null,
    user_email:      String(r[1] || ''),
    user_name:       String(r[2] || ''),
    change_type:     String(r[3] || ''),
    item_id:         String(r[4] || ''),
    brand:           String(r[5] || ''),
    series_or_size:  String(r[6] || ''),
    orientation:     String(r[7] || ''),
    condition:       String(r[8] || ''),
    old_qty:         toNumber(r[9]),
    new_qty:         toNumber(r[10]),
    delta:           toNumber(r[11]),
    job_ref:         String(r[12] || ''),
    note:            '' // no dedicated note column in current layout
  }));

  return {
    status: 'ok',
    changes: changes
  };
}

/**************************************
 * LIFTS MASTER
 **************************************/

function apiGetLifts() {
  const ss = getSs();
  const sheet = ss.getSheetByName(SHEET_LIFTS_MASTER);
  const values = sheet.getDataRange().getValues();
  const rows = values.slice(1); // skip header

  const lifts = rows
    .filter(r => r[0] !== '' && r[0] !== null) // lift_id
    .map(r => ({
      lift_id:         String(r[0] || ''),
      serial_number:   String(r[1] || ''),
      brand:           String(r[2] || ''),
      series:          String(r[3] || ''),
      orientation:     String(r[4] || ''),
      fold_type:       String(r[5] || ''),
      condition:       String(r[6] || ''),
      date_acquired:   String(r[7] || ''),
      status:          String(r[8] || ''),
      current_location:String(r[9] || ''),
      current_job:     String(r[10] || ''),
      install_date:    String(r[11] || ''),
      installer_name:  String(r[12] || ''),
      prepped_status:  String(r[13] || ''),
      last_prep_date:  String(r[14] || ''),
      notes:           String(r[15] || '')
    }));

  return {
    status: 'ok',
    lifts: lifts
  };
}

/**************************************
 * LIFT HISTORY
 **************************************/

function apiGetLiftHistory(params) {
  const serial = (params.serial_number || '').toString().trim();
  if (!serial) {
    return { status: 'ok', history: [] };
  }

  const ss = getSs();
  const sheet = ss.getSheetByName(SHEET_LIFT_HISTORY);
  const values = sheet.getDataRange().getValues();
  const rows = values.slice(1); // skip header

  const history = rows
    .filter(r => String(r[2] || '').trim() === serial) // lift_id column
    .map(r => ({
      // Sheet columns:
      // 0: timestamp
      // 1: lift_id
      // 2: serial_number
      // 3: event_type
      // 4: from_status
      // 5: to_status
      // 6: from_location
      // 7: to_location
      // 8: from_customer
      // 9: to_customer
      // 10: job_ref
      // 11: note
      // 12: user_email
      // 13: user_name
      timestamp: r[0] ? new Date(r[0]) : null,
      status:    String(r[5] || r[4] || ''),      // prefer to_status
      location:  String(r[7] || r[6] || ''),      // prefer to_location
      job_ref:   String(r[10] || ''),
      note:      String(r[11] || '')
    }));

  return {
    status: 'ok',
    history: history
  };
}

/**************************************
 * LIFT SERVICE
 **************************************/

function apiGetLiftService(params) {
  const ss = getSs();
  const serviceSheet = ss.getSheetByName(SHEET_LIFT_SERVICE);

  if (!serviceSheet) {
    return { status: 'ok', service: [] };
  }

  const values = serviceSheet.getDataRange().getValues();
  const rows   = values.slice(1); // skip header

  const liftIdParam  = (params.lift_id || '').toString().trim();
  const serialParam  = (params.serial_number || '').toString().trim();

  // DEBUG: Log what we received
  Logger.log('=== DEBUG GET LIFT SERVICE ===');
  Logger.log('Received liftId: [' + liftIdParam + ']');
  Logger.log('Received serial: [' + serialParam + ']');
  Logger.log('Total rows in sheet: ' + rows.length);

  // DEBUG: Log what's in the sheet
  rows.forEach((r, i) => {
    const rowLiftId = String(r[1] || '').trim();
    const rowSerial = String(r[2] || '').trim();
    Logger.log('Row ' + i + ' - liftId: [' + rowLiftId + '], serial: [' + rowSerial + ']');
  });

  // If we have literally nothing to key off, just return empty
  if (!liftIdParam && !serialParam) {
    Logger.log('No params provided, returning empty');
    return { status: 'ok', service: [] };
  }

  const serviceRows = rows
    .filter(r => {
      const rowLiftId = String(r[1] || '').trim(); // lift_id
      const rowSerial = String(r[2] || '').trim(); // serial_number

      // 1) Primary: exact serial match
      if (serialParam && rowSerial === serialParam) {
        Logger.log('MATCH FOUND on serial: ' + rowSerial);
        return true;
      }

      // 2) Fallbacks: allow lift_id matches when serial isn't usable
      if (!serialParam && liftIdParam && rowLiftId === liftIdParam) {
        Logger.log('MATCH FOUND on liftId: ' + rowLiftId);
        return true;
      }
      if (liftIdParam && rowLiftId === liftIdParam && !rowSerial) {
        Logger.log('MATCH FOUND on liftId (no serial): ' + rowLiftId);
        return true;
      }

      return false;
    })
    .map(r => ({
      service_date:     r[3] ? new Date(r[3]) : null,
      service_type:     String(r[4] || ''),
      description:      String(r[5] || ''),
      invoice_number:   String(r[6] || ''),
      technician_name:  String(r[7] || ''),
      job_ref:          String(r[8] || ''),
      customer_name:    String(r[9] || ''),
      notes:            String(r[10] || '')
    }));

  Logger.log('Filtered service rows: ' + serviceRows.length);

  return {
    status: 'ok',
    service: serviceRows
  };
}

/**************************************
 * FULL CHECK – Sets absolute quantities for ramps
 **************************************/

function apiFullCheck(params) {
  const userEmail = (params.user_email || '').toString();
  const userName  = (params.user_name || '').toString();
  const items     = params.items || [];

  if (!items || !items.length) {
    return { status: 'ok', updated: 0 };
  }

  const ss = getSs();
  const rampsSheet   = ss.getSheetByName(SHEET_RAMPS);
  const changesSheet = ss.getSheetByName(SHEET_CHANGES);

  const rampValues = rampsSheet.getDataRange().getValues();
  const rampRows   = rampValues.slice(1);

  // Build a map of item_id|condition -> row index
  // This matches the Job Adjustment logic to find the correct row
  const itemIndexByKey = {};
  rampRows.forEach((r, i) => {
    const id = String(r[0] || '').trim();
    const cond = String(r[3] || '').trim(); // condition is column D
    if (id) {
      const key = id + '|' + cond;
      itemIndexByKey[key] = i + 2; // +2 for header and 1-based indexing
    }
  });

  let updatedCount = 0;
  const now = new Date();

  items.forEach(it => {
    const itemId    = String(it.item_id || '').trim();
    const condition = String(it.condition || '').trim();
    const newQty    = toNumber(it.new_qty);

    const key = itemId + '|' + condition;
    const rowIndex = itemIndexByKey[key];

    if (!rowIndex) {
      Logger.log('Full Check: item not found for key: ' + key);
      return;
    }

    // Get the current row data
    const row = rampsSheet.getRange(rowIndex, 1, 1, 6).getValues()[0];
    const currentQty = toNumber(row[4]); // column E (current_qty)
    const delta = newQty - currentQty;

    // Update the quantity in the sheet
    rampsSheet.getRange(rowIndex, 5).setValue(newQty); // column E

    Logger.log('Full Check: Updated ' + key + ' from ' + currentQty + ' to ' + newQty);

    // Append to Inventory_Changes
    changesSheet.appendRow([
      now,                    // 0 timestamp
      userEmail,              // 1 user_email
      userName,               // 2 user_name
      'Full Check',           // 3 change_type
      itemId,                 // 4 item_id
      String(row[1] || ''),   // 5 brand
      String(row[2] || ''),   // 6 size / series_or_size
      '',                     // 7 orientation
      condition,              // 8 condition
      currentQty,             // 9 old_qty
      newQty,                 // 10 new_qty
      delta,                  // 11 delta
      ''                      // 12 job_ref (empty for full check)
    ]);

    updatedCount++;
  });

  return { status: 'ok', updated: updatedCount };
}

/**************************************
 * JOB ADJUSTMENT – Ramps only (as used now)
 **************************************/

function apiJobAdjustment(params) {
  const userEmail = (params.user_email || '').toString();
  const userName  = (params.user_name || '').toString();
  const jobRef    = (params.job_ref || '').toString();
  const items     = params.items || [];

  if (!items || !items.length) {
    return { status: 'ok', updated: 0 };
  }

  const ss = getSs();
  const rampsSheet   = ss.getSheetByName(SHEET_RAMPS);
  const changesSheet = ss.getSheetByName(SHEET_CHANGES);

  const rampValues = rampsSheet.getDataRange().getValues();
  const rampRows   = rampValues.slice(1);

  // Build a map of item_id|condition -> row index
  // This is the FIX: we need to match both item_id AND condition
  const itemIndexByKey = {};
  rampRows.forEach((r, i) => {
    const id = String(r[0] || '').trim();
    const cond = String(r[3] || '').trim(); // condition is column D
    if (id) {
      const key = id + '|' + cond;
      itemIndexByKey[key] = i + 2; // +2 for header and 1-based indexing
    }
  });

  let updatedCount = 0;
  const now = new Date();

  items.forEach(it => {
    const itemId    = String(it.item_id || '').trim();
    const condition = String(it.condition || '').trim();
    const delta     = toNumber(it.delta);

    const key = itemId + '|' + condition;
    const rowIndex = itemIndexByKey[key];

    if (!rowIndex) {
      Logger.log('Job Adjustment: item not found for key: ' + key);
      return;
    }

    const row = rampsSheet.getRange(rowIndex, 1, 1, 6).getValues()[0];
    const currentQty = toNumber(row[4]);
    const newQty     = currentQty + delta;

    rampsSheet.getRange(rowIndex, 5).setValue(newQty);

    Logger.log('Job Adjustment: Updated ' + key + ' from ' + currentQty + ' to ' + newQty + ' (delta: ' + delta + ')');

    // Append to Inventory_Changes with the same 13-column layout
    changesSheet.appendRow([
      now,                                    // 0 timestamp
      userEmail,                              // 1 user_email
      userName,                               // 2 user_name
      delta < 0 ? 'Job Install' : 'Job Removal', // 3 change_type
      itemId,                                 // 4 item_id
      String(row[1] || ''),                   // 5 brand
      String(row[2] || ''),                   // 6 size / series_or_size
      '',                                     // 7 orientation
      condition,                              // 8 condition
      currentQty,                             // 9 old_qty
      newQty,                                 // 10 new_qty
      delta,                                  // 11 delta
      jobRef                                  // 12 job_ref
    ]);

    updatedCount++;
  });

  return { status: 'ok', updated: updatedCount };
}

/**************************************
 * UPSERT LIFT (create/update + history)
 * Now more robust: updates by lift_id OR serial_number
 **************************************/

function apiUpsertLift(params) {
  const userEmail      = (params.user_email || '').toString();
  const userName       = (params.user_name || '').toString();

  let   liftId         = (params.lift_id || '').toString().trim();
  const serialNumber   = (params.serial_number || '').toString().trim();
  const brand          = (params.brand || '').toString();
  const series         = (params.series || '').toString();
  const orientation    = (params.orientation || '').toString();
  const foldType       = (params.fold_type || '').toString();
  const condition      = (params.condition || '').toString();
  const status         = (params.status || '').toString();
  const preppedStatus  = (params.prepped_status || '').toString();
  const currentLocation= (params.current_location || '').toString();
  const currentJob     = (params.current_job || '').toString();
  const dateAcquired   = (params.date_acquired || '').toString();
  const installDate    = (params.install_date || '').toString();
  const installerName  = (params.installer_name || '').toString();
  const lastPrepDate   = (params.last_prep_date || '').toString();
  const notes          = (params.notes || '').toString();

  const ss = getSs();
  const masterSheet  = ss.getSheetByName(SHEET_LIFTS_MASTER);
  const historySheet = ss.getSheetByName(SHEET_LIFT_HISTORY);

  const masterValues = masterSheet.getDataRange().getValues();
  const masterRows   = masterValues.slice(1);
  const lastCol      = masterValues[0].length;

  let rowIndex = -1; // sheet row index (1-based)
  let maxId = 0;

  // First pass: find maxId and try to match by trimmed lift_id
  masterRows.forEach((r, i) => {
    const rawId = r[0];
    const idStr = rawId !== '' && rawId !== null ? String(rawId).trim() : '';
    if (idStr) {
      const numId = Number(idStr);
      if (!isNaN(numId) && numId > maxId) {
        maxId = numId;
      }
    }

    if (liftId && idStr && idStr === liftId && rowIndex < 0) {
      rowIndex = i + 2; // +2 because of header
    }
  });

  // Second pass: if we still didn't find a row and we have a serial,
  // try matching by serial_number (column 1). This lets you update
  // older rows even if lift_id was blank or mismatched.
  if (rowIndex < 0 && serialNumber) {
    masterRows.forEach((r, i) => {
      const rowSerial = String(r[1] || '').trim();
      if (rowSerial && rowSerial === serialNumber && rowIndex < 0) {
        rowIndex = i + 2;
        const idStr = String(r[0] || '').trim();
        if (idStr) {
          liftId = idStr; // Reuse existing lift_id
        }
      }
    });
  }

  let prevStatus = '';
  let prevLocation = '';

  if (rowIndex > 0) {
    const existing = masterSheet.getRange(rowIndex, 1, 1, lastCol).getValues()[0];
    prevStatus   = String(existing[8] || '');
    prevLocation = String(existing[9] || '');
  }

  // If still no liftId, create a new one
  if (!liftId) {
    liftId = String(maxId + 1);
  }

  const newRowValues = [
    liftId,
    serialNumber,
    brand,
    series,
    orientation,
    foldType,
    condition,
    dateAcquired,
    status,
    currentLocation,
    currentJob,
    installDate,
    installerName,
    preppedStatus,
    lastPrepDate,
    notes
  ];

  if (rowIndex > 0) {
    // Update existing row
    masterSheet.getRange(rowIndex, 1, 1, newRowValues.length).setValues([newRowValues]);
  } else {
    // Append new row
    rowIndex = masterSheet.getLastRow() + 1;
    masterSheet.appendRow(newRowValues);
  }

  // Write history – ensure columns line up EXACTLY with header:
  // [timestamp, lift_id, serial_number, event_type, from_status, to_status,
  //  from_location, to_location, from_customer, to_customer, job_ref, note,
  //  user_email, user_name]
  const now = new Date();
  const eventType = prevStatus || prevLocation ? 'Updated' : 'Created';

  const historyRow = [
    now,                // timestamp
    liftId,             // lift_id
    serialNumber,       // serial_number
    eventType,          // event_type
    prevStatus,         // from_status
    status,             // to_status
    prevLocation,       // from_location
    currentLocation,    // to_location
    '',                 // from_customer
    '',                 // to_customer
    currentJob,         // job_ref
    notes,              // note
    userEmail,          // user_email
    userName            // user_name
  ];

  historySheet.appendRow(historyRow);

  return {
    status: 'ok',
    lift_id: liftId
  };
}

/**************************************
 * ADD LIFT SERVICE
 **************************************/

function apiAddLiftService(params) {
  const userEmail     = (params.user_email || '').toString();
  const userName      = (params.user_name || '').toString();
  const liftId        = (params.lift_id || '').toString().trim();
  let   serialNumber  = (params.serial_number || '').toString().trim();
  const serviceDate   = (params.service_date || '').toString();
  const serviceType   = (params.service_type || '').toString();
  const description   = (params.description || '').toString();
  const invoiceNumber = (params.invoice_number || '').toString();
  const jobRef        = (params.job_ref || '').toString();
  const customerName  = (params.customer_name || '').toString();
  const notes         = (params.notes || '').toString();

  const ss = getSs();
  const serviceSheet = ss.getSheetByName(SHEET_LIFT_SERVICE);

  // Fallback: if serialNumber is blank but we have a liftId, try to look it up
  if (!serialNumber && liftId) {
    const masterSheet  = ss.getSheetByName(SHEET_LIFTS_MASTER);
    const masterValues = masterSheet.getDataRange().getValues();
    const masterRows   = masterValues.slice(1);

    masterRows.forEach(r => {
      if (String(r[0] || '').trim() === liftId) { // lift_id column
        serialNumber = String(r[1] || '').trim(); // serial_number column
      }
    });
  }

  const now = new Date();

  // Columns:
  // 0: timestamp
  // 1: lift_id
  // 2: serial_number
  // 3: service_date
  // 4: service_type
  // 5: description
  // 6: invoice_number
  // 7: technician_name
  // 8: job_ref
  // 9: customer_name
  // 10: notes
  // 11: entered_by_email
  // 12: entered_by_name
  const row = [
    now,
    liftId,
    serialNumber,
    serviceDate,
    serviceType,
    description,
    invoiceNumber,
    userName,     // technician_name
    jobRef,
    customerName,
    notes,
    userEmail,
    userName
  ];

  serviceSheet.appendRow(row);

  return { status: 'ok' };
}

/**************************************
 * DELETE LIFT (from LIFTS_MASTER + history entry)
 **************************************/

function apiDeleteLift(params) {
  const userEmail = (params.user_email || '').toString();
  const userName  = (params.user_name || '').toString();
  const liftId    = (params.lift_id || '').toString().trim();

  if (!liftId) {
    return { status: 'error', message: 'lift_id is required to delete a lift.' };
  }

  const ss = getSs();
  const masterSheet  = ss.getSheetByName(SHEET_LIFTS_MASTER);
  const historySheet = ss.getSheetByName(SHEET_LIFT_HISTORY);

  const values = masterSheet.getDataRange().getValues();
  const rows   = values.slice(1); // skip header

  let deletedRowValues = null;
  let deleteRowIndex   = -1;

  for (let i = 0; i < rows.length; i++) {
    const rowLiftId = String(rows[i][0] || '').trim();
    if (rowLiftId === liftId) {
      deletedRowValues = rows[i];
      deleteRowIndex = i + 2; // +2 to account for header row + 1-based index
      break;
    }
  }

  if (deleteRowIndex < 0) {
    return { status: 'error', message: 'Lift not found for lift_id: ' + liftId };
  }

  const serialNumber = String(deletedRowValues[1] || '');
  const prevStatus   = String(deletedRowValues[8] || '');
  const prevLocation = String(deletedRowValues[9] || '');

  // Delete the row
  masterSheet.deleteRow(deleteRowIndex);

  // Log a "Deleted" event in Lift_History
  const now = new Date();
  const historyRow = [
    now,                 // timestamp
    liftId,              // lift_id
    serialNumber,        // serial_number
    'Deleted',           // event_type
    prevStatus,          // from_status
    '',                  // to_status
    prevLocation,        // from_location
    '',                  // to_location
    '',                  // from_customer
    '',                  // to_customer
    '',                  // job_ref
    'Lift deleted',      // note
    userEmail,           // user_email
    userName             // user_name
  ];
  historySheet.appendRow(historyRow);

  return { status: 'ok', deleted: true };
}

/**************************************
 * PICKUP LIST
 **************************************/
function apiGetPickupList() {
  try {
    const ss = getSs();
    const sheet = ss.getSheetByName(SHEET_PICKUP_LIST);
    if (!sheet) return { status: 'ok', items: [] };

    const values = sheet.getDataRange().getValues();
    if (values.length < 2) return { status: 'ok', items: [] };

    const rows = values.slice(1); // skip header
    const header = values[0];

    const colIndexes = {};
    header.forEach((h, i) => {
      colIndexes[h.toString().trim().toLowerCase()] = i;
    });

    const items = rows.map(r => ({
      id:           r[colIndexes['id']],
      item:         r[colIndexes['item']],
      added_by:     r[colIndexes['added_by']],
      added_at:     r[colIndexes['added_at']],
      completed:    r[colIndexes['completed']] === true || r[colIndexes['completed']] === 'TRUE',
      completed_by: r[colIndexes['completed_by']],
      completed_at: r[colIndexes['completed_at']]
    }));

    return { status: 'ok', items: items };
  } catch (e) {
    Logger.log('apiGetPickupList error: ' + e);
    return { status: 'error', message: 'internal' };
  }
}

function apiAddPickupItem(params) {
  try {
    const itemText = (params.item || '').toString().trim();
    const addedBy  = (params.added_by || '').toString().trim();
    if (!itemText || !addedBy) return { status: 'error', message: 'Missing required fields' };

    const ss = getSs();
    const sheet = ss.getSheetByName(SHEET_PICKUP_LIST);
    if (!sheet) return { status: 'error', message: 'Sheet not found' };

    const timestamp = new Date();
    const id = timestamp.getTime().toString(); // unique ID

    sheet.appendRow([id, itemText, addedBy, timestamp, 'FALSE', '', '']);

    return { status: 'ok', id: id };
  } catch (e) {
    Logger.log('apiAddPickupItem error: ' + e);
    return { status: 'error', message: 'internal' };
  }
}

function apiUpdatePickupItem(params) {
  try {
    const itemId = (params.id || '').toString().trim();
    if (!itemId) return { status: 'error', message: 'Missing id' };

    const completed = params.completed === true || params.completed === 'TRUE';
    const completedBy = (params.completed_by || '').toString().trim();
    const completedAt = completed ? new Date() : '';

    const ss = getSs();
    const sheet = ss.getSheetByName(SHEET_PICKUP_LIST);
    if (!sheet) return { status: 'error', message: 'Sheet not found' };

    const values = sheet.getDataRange().getValues();
    if (values.length < 2) return { status: 'error', message: 'No rows found' };

    const header = values[0];
    const colIndexes = {};
    header.forEach((h, i) => {
      colIndexes[h.toString().trim().toLowerCase()] = i;
    });

    for (let i = 1; i < values.length; i++) {
      const rowId = String(values[i][colIndexes['id']] || '').trim();
      if (rowId === itemId) {
        sheet.getRange(i + 1, colIndexes['completed'] + 1).setValue(completed ? 'TRUE' : 'FALSE');
        sheet.getRange(i + 1, colIndexes['completed_by'] + 1).setValue(completedBy);
        sheet.getRange(i + 1, colIndexes['completed_at'] + 1).setValue(completedAt);
        return { status: 'ok' };
      }
    }

    return { status: 'error', message: 'Item not found' };
  } catch (e) {
    Logger.log('apiUpdatePickupItem error: ' + e);
    return { status: 'error', message: 'internal: ' + e.message };
  }
}

/**************************************
 * PREP CHECKLISTS
 **************************************/

/**
 * Get all prep checklists for a given serial number
 */
function apiGetPrepChecklists(params) {
  try {
    const serialNumber = (params.serial_number || '').toString().trim();
    if (!serialNumber) {
      return { status: 'error', message: 'serial_number is required' };
    }

    const ss = getSs();
    const sheet = ss.getSheetByName(SHEET_PREP_CHECKLISTS);
    if (!sheet) {
      return { status: 'ok', checklists: [] };
    }

    const values = sheet.getDataRange().getValues();
    if (values.length < 2) {
      return { status: 'ok', checklists: [] };
    }

    const header = values[0];
    const rows = values.slice(1);

    // Build column index map
    const colIndexes = {};
    header.forEach((h, i) => {
      colIndexes[h.toString().trim().toLowerCase().replace(/_/g, '_')] = i;
    });

    // Filter rows by serial number and convert to objects
    const checklists = rows
      .filter(r => String(r[colIndexes['serial_number']] || '').trim() === serialNumber)
      .map(r => {
        const checklist = {};
        header.forEach((h, i) => {
          const key = h.toString().trim().toLowerCase().replace(/ /g, '_');
          let value = r[i];

          // Convert TRUE/FALSE strings to booleans for checklist items
          if (value === 'TRUE') value = true;
          if (value === 'FALSE') value = false;

          checklist[key] = value;
        });
        return checklist;
      });

    return {
      status: 'ok',
      checklists: checklists
    };

  } catch (e) {
    Logger.log('apiGetPrepChecklists error: ' + e);
    return { status: 'error', message: 'internal: ' + e.message };
  }
}

/**
 * Save a prep checklist (new or update existing)
 */
function apiSavePrepChecklist(params) {
  try {
    const checklistId = (params.checklist_id || '').toString().trim();
    const serialNumber = (params.serial_number || '').toString().trim();
    const brand = (params.brand || '').toString().trim();
    const series = (params.series || '').toString().trim();

    if (!serialNumber) {
      return { status: 'error', message: 'serial_number is required' };
    }

    const ss = getSs();
    const sheet = ss.getSheetByName(SHEET_PREP_CHECKLISTS);
    if (!sheet) {
      return { status: 'error', message: 'Prep_Checklists sheet not found' };
    }

    const values = sheet.getDataRange().getValues();
    const header = values[0];

    // Build column index map
    const colIndexes = {};
    header.forEach((h, i) => {
      colIndexes[h.toString().trim().toLowerCase().replace(/ /g, '_')] = i;
    });

    const now = new Date();
    let newChecklistId = checklistId;
    let rowIndex = -1;

    // If updating, find the existing row
    if (checklistId) {
      const rows = values.slice(1);
      for (let i = 0; i < rows.length; i++) {
        if (String(rows[i][colIndexes['checklist_id']] || '').trim() === checklistId) {
          rowIndex = i + 2; // +2 for header and 1-based index
          break;
        }
      }
    }

    // If no checklist_id or not found, create new
    if (!newChecklistId || rowIndex < 0) {
      newChecklistId = now.getTime().toString();
      rowIndex = -1; // Signal to append
    }

    // Build the row data matching the header order
    const rowData = new Array(header.length).fill('');

    // Set common fields
    rowData[colIndexes['checklist_id']] = newChecklistId;
    rowData[colIndexes['timestamp']] = now;
    rowData[colIndexes['serial_number']] = serialNumber;
    rowData[colIndexes['brand']] = brand;
    rowData[colIndexes['series']] = series;

    // Copy all other fields from params
    Object.keys(params).forEach(key => {
      const normalizedKey = key.toLowerCase().replace(/ /g, '_');
      if (colIndexes[normalizedKey] !== undefined) {
        let value = params[key];
        // Convert boolean values to TRUE/FALSE strings
        if (value === true) value = 'TRUE';
        if (value === false) value = 'FALSE';
        rowData[colIndexes[normalizedKey]] = value;
      }
    });

    if (rowIndex > 0) {
      // Update existing row
      sheet.getRange(rowIndex, 1, 1, rowData.length).setValues([rowData]);
    } else {
      // Append new row
      sheet.appendRow(rowData);
    }

    // Also update the lift's prepped_status and last_prep_date in Lifts_Master
    const masterSheet = ss.getSheetByName(SHEET_LIFTS_MASTER);
    const masterValues = masterSheet.getDataRange().getValues();
    const masterRows = masterValues.slice(1);

    for (let i = 0; i < masterRows.length; i++) {
      if (String(masterRows[i][1] || '').trim() === serialNumber) { // serial_number is column 1
        const liftRowIndex = i + 2;
        masterSheet.getRange(liftRowIndex, 14).setValue('Prepped'); // prepped_status column
        masterSheet.getRange(liftRowIndex, 15).setValue(now); // last_prep_date column
        break;
      }
    }

    return {
      status: 'ok',
      checklist_id: newChecklistId
    };

  } catch (e) {
    Logger.log('apiSavePrepChecklist error: ' + e);
    return { status: 'error', message: 'internal: ' + e.message };
  }
}

/**
 * Get checklist template based on lift type (brand + series)
 */
function apiGetPrepChecklistTemplate(params) {
  try {
    const brand = (params.brand || '').toString().trim().toLowerCase();
    const series = (params.series || '').toString().trim().toLowerCase();

    // Determine which checklist fields to return based on brand/series
    let checklistType = '';
    if (brand.includes('bruno') && series.includes('elan')) {
      checklistType = 'bruno_elan';
    } else if (brand.includes('bruno') && series.includes('elite')) {
      checklistType = 'bruno_elite';
    } else if (brand.includes('acorn') || brand.includes('brooks')) {
      checklistType = 'brooks_acorn';
    } else {
      return { status: 'error', message: 'Unknown lift type' };
    }

    // Return the appropriate field list for the checklist type
    const templates = {
      bruno_elan: [
        'seat_hardware',
        'carriage',
        'seatbelt',
        'footplate_hardware',
        'track_measurement',
        'double_check_track_measurement',
        'top_final_limit_cam',
        'charge_strips',
        'end_plates_hardware',
        'charge_contact',
        'joint_kit_screws',
        'rail_stand_feet_t_nuts',
        'charger_power_cord',
        'remotes_cradles',
        'seat_post_nylon_washers_retaining_clip',
        'gear_rack_for_length_of_track',
        'soft_stops_if_needed',
        'extension_brackets_if_needed',
        'folding_rail_yes_no',
        'folding_rail_bottom_foot',
        'spacer_end_plate',
        'check_seat_armrests_stay_up',
        'check_wires_in_arm',
        'paperwork',
        'owners_manual'
      ],
      bruno_elite: [
        'seat_hardware',
        'carriage',
        'seatbelt',
        'footplate_hardware',
        'track_measurement',
        'double_check_track_measurement',
        'top_final_limit_cam',
        'charge_strips',
        'end_plates_hardware',
        'charge_contact',
        'joint_kit_screws',
        'rail_stand_feet_t_nuts',
        'charger_power_cord',
        'remotes_cradles',
        'seat_post_nylon_washers_retaining_clip',
        'gear_rack_for_length_of_track',
        'soft_stops_if_needed',
        'extension_brackets_if_needed',
        'rear_seat_support_bracket',
        'spacer_end_plate',
        'check_seat_armrests_stay_up',
        'check_wires_in_arm',
        'paperwork',
        'owners_manual'
      ],
      brooks_acorn: [
        'rh_unit_or_lh_unit',
        'correct_handed_carriage',
        'correct_handed_seat',
        'charger_type_130_black_t700_white',
        'correct_num_feet_brackets_hardware_lags',
        'end_plate_covers_top_bottom',
        'remotes_hanging_hooks',
        'key_if_needed',
        'seat_swivel_switch_actuator',
        'two_seat_cushions',
        'seat_post_retaining_plug',
        'extension_brackets_if_needed',
        'top_final_limit_cam',
        'rack_end_stop_if_needed',
        'charge_stations',
        'hole_in_rail_for_charging_wire',
        'seat_index_plate_cover',
        'hand_winding_wheel',
        'check_seat_armrests_stay_up',
        'folding_rail_yes_no',
        't130_remove_h_cam_from_track',
        't700_make_sure_h_cam_installed',
        'outdoor_yes_no',
        'outdoor_box_for_charger',
        'outlet_cover',
        'paperwork',
        'owners_manual'
      ]
    };

    return {
      status: 'ok',
      checklist_type: checklistType,
      fields: templates[checklistType]
    };

  } catch (e) {
    Logger.log('apiGetPrepChecklistTemplate error: ' + e);
    return { status: 'error', message: 'internal: ' + e.message };
  }
}
