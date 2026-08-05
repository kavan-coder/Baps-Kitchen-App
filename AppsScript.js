function doPost(e) {
  try {
    var payload = JSON.parse(e.postData.contents || "{}");
    var spreadsheet = SpreadsheetApp.getActiveSpreadsheet();

    var inventorySheet = spreadsheet.getSheetByName(payload.sheetName);
    if (!inventorySheet) {
      return jsonResponse({ success: false, error: "Inventory worksheet not found." });
    }

    var values = inventorySheet.getDataRange().getValues();
    if (values.length === 0) {
      return jsonResponse({ success: false, error: "Inventory worksheet is empty." });
    }

    var headers = values[0].map(normalizeHeader);
    var nameColumn = headers.indexOf("item name") >= 0 ? headers.indexOf("item name") : headers.indexOf("name");
    var quantityColumn = headers.indexOf("stock") >= 0 ? headers.indexOf("stock") : headers.indexOf("quantity");

    if (nameColumn === -1 || quantityColumn === -1) {
      return jsonResponse({ success: false, error: "Required inventory columns are missing." });
    }

    var rowIndex = -1;
    for (var i = 1; i < values.length; i++) {
      if (normalizeValue(values[i][nameColumn]) === normalizeValue(payload.originalName)) {
        rowIndex = i + 1;
        break;
      }
    }

    if (rowIndex === -1) {
      return jsonResponse({ success: false, error: "Item not found in worksheet." });
    }

    inventorySheet.getRange(rowIndex, nameColumn + 1).setValue(payload.newName || payload.originalName);
    inventorySheet.getRange(rowIndex, quantityColumn + 1).setValue(payload.newQuantity || "");

    var previousQuantity = String(payload.previousQuantity || "").trim();
    var newQuantity = String(payload.newQuantity || "").trim();
    if (payload.changeSheetName && previousQuantity !== newQuantity) {
      appendChangeLog(spreadsheet, payload.changeSheetName, {
        user: payload.editorName || "Unknown User",
        item: payload.newName || payload.originalName || "",
        previousQuantity: previousQuantity,
        newQuantity: newQuantity,
        changeDisplayText: payload.changeDisplayText || "",
        changeDisplayColor: payload.changeDisplayColor || ""
      });
    }

    return jsonResponse({ success: true });
  } catch (error) {
    return jsonResponse({ success: false, error: error.message || String(error) });
  }
}

function appendChangeLog(spreadsheet, sheetName, change) {
  var logSheet = spreadsheet.getSheetByName(sheetName);
  if (!logSheet) {
    throw new Error("Change worksheet not found: " + sheetName);
  }

  var lastColumn = Math.max(logSheet.getLastColumn(), 12);
  var headers = logSheet.getRange(1, 1, 1, lastColumn).getValues()[0].map(normalizeHeader);
  var row = new Array(lastColumn).fill("");

  var timestampColumn = headers.indexOf("timestamp");
  var userColumn = headers.indexOf("user");
  var itemColumn = headers.indexOf("item");
  var changeColumn = headers.indexOf("change");
  var changeDisplay = change.changeDisplayText
    ? {
        text: change.changeDisplayText,
        color: change.changeDisplayColor || "#444444"
      }
    : calculateChangeDisplay(change.previousQuantity, change.newQuantity);

  if (timestampColumn >= 0) {
    row[timestampColumn] = new Date();
  }
  if (userColumn >= 0) {
    row[userColumn] = change.user;
  }
  if (itemColumn >= 0) {
    row[itemColumn] = change.item;
  }
  if (changeColumn >= 0) {
    row[changeColumn] = changeDisplay.text;
  }

  logSheet.appendRow(row);

  if (changeColumn >= 0) {
    var appendedRowIndex = logSheet.getLastRow();
    var changeCell = logSheet.getRange(appendedRowIndex, changeColumn + 1);
    changeCell.setFontColor(changeDisplay.color);
  }
}

function jsonResponse(payload) {
  return ContentService
    .createTextOutput(JSON.stringify(payload))
    .setMimeType(ContentService.MimeType.JSON);
}

function normalizeHeader(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[_\s]+/g, " ");
}

function normalizeValue(value) {
  return String(value || "").trim().toLowerCase();
}

function calculateChangeDisplay(previousQuantity, newQuantity) {
  var previousValue = parseQuantity(previousQuantity);
  var newValue = parseQuantity(newQuantity);

  if (previousValue === null || newValue === null) {
    return {
      text: String(previousQuantity || "") + " -> " + String(newQuantity || ""),
      color: "#444444"
    };
  }

  var delta = newValue - previousValue;
  if (delta > 0) {
    return { text: "+" + delta, color: "#1b8f3a" };
  }
  if (delta < 0) {
    return { text: String(delta), color: "#c62828" };
  }
  return { text: "0", color: "#444444" };
}

function parseQuantity(value) {
  var normalized = String(value || "").trim();
  if (!normalized) {
    return null;
  }

  var numericPortion = normalized.replace(/[^0-9.-]/g, "");
  if (!numericPortion) {
    return null;
  }

  var parsed = Number(numericPortion);
  return isNaN(parsed) ? null : parsed;
}
