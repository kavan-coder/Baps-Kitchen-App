const fs = require('fs');
const path = require('path');
const ExcelJS = require('exceljs');

const DOWNLOADS_DIR = path.join(process.env.HOME, 'Downloads');
const WORKBOOK_PATH = path.join(DOWNLOADS_DIR, 'Kothar Inventory.xlsx');
const BACKUP_PATH = path.join(DOWNLOADS_DIR, 'Kothar Inventory.backup.xlsx');
const INVENTORY_SHEET = 'Inventory';
const CATEGORY_SHEETS = ['Inventory', 'Snacks', 'Farari', 'Spices'];

function headerIndexMap(headerRow) {
  const map = new Map();
  headerRow.eachCell((cell, colNumber) => {
    const key = String(cell.value || '').trim().toLowerCase();
    if (key) {
      map.set(key, colNumber);
    }
  });
  return map;
}

function readCategoryRows(sheet, categoryName) {
  const rows = [];
  const headers = headerIndexMap(sheet.getRow(1));
  const nameCol = headers.get('name');
  const quantityCol = headers.get('quantity');
  const unitCol = headers.get('unit');

  if (!nameCol || !quantityCol || !unitCol) {
    throw new Error(`Sheet "${categoryName}" must contain Name, Quantity, and Unit headers.`);
  }

  sheet.eachRow((row, rowNumber) => {
    if (rowNumber === 1) {
      return;
    }

    const name = String(row.getCell(nameCol).value ?? '').trim();
    const quantity = String(row.getCell(quantityCol).value ?? '').trim();
    const unit = String(row.getCell(unitCol).value ?? '').trim();

    if (!name) {
      return;
    }

    rows.push([categoryName, name, quantity, unit]);
  });

  return rows;
}

function styleHeader(row) {
  row.font = { bold: true, color: { argb: 'FFFFFFFF' } };
  row.fill = {
    type: 'pattern',
    pattern: 'solid',
    fgColor: { argb: 'FF2F6B5F' },
  };
  row.alignment = { vertical: 'middle' };
}

function replaceWorksheet(workbook, sheetName) {
  const existingSheet = workbook.getWorksheet(sheetName);
  if (!existingSheet) {
    return workbook.addWorksheet(sheetName);
  }

  const sheetId = existingSheet.id;
  const targetIndex = workbook.worksheets.findIndex((sheet) => sheet.id === sheetId);
  workbook.removeWorksheet(sheetId);

  const newSheet = workbook.addWorksheet(sheetName);
  if (targetIndex >= 0) {
    const movedSheet = workbook._worksheets.pop();
    workbook._worksheets.splice(targetIndex + 1, 0, movedSheet);
  }

  return newSheet;
}

async function main() {
  if (!fs.existsSync(WORKBOOK_PATH)) {
    throw new Error(`Workbook not found at ${WORKBOOK_PATH}.`);
  }

  if (!fs.existsSync(BACKUP_PATH)) {
    fs.copyFileSync(WORKBOOK_PATH, BACKUP_PATH);
  }

  const sourceWorkbook = new ExcelJS.Workbook();
  await sourceWorkbook.xlsx.readFile(BACKUP_PATH);

  const workbook = new ExcelJS.Workbook();
  await workbook.xlsx.readFile(WORKBOOK_PATH);

  const groupedRows = [];
  for (const sheetName of CATEGORY_SHEETS) {
    const sheet = sourceWorkbook.getWorksheet(sheetName);
    if (!sheet) {
      throw new Error(`Sheet "${sheetName}" was not found in the workbook.`);
    }
    groupedRows.push(...readCategoryRows(sheet, sheetName));
  }

  const inventorySheet = replaceWorksheet(workbook, INVENTORY_SHEET);

  inventorySheet.addRow(['Category', 'Name', 'Quantity', 'Unit']);
  for (const values of groupedRows) {
    inventorySheet.addRow(values);
  }

  styleHeader(inventorySheet.getRow(1));
  inventorySheet.views = [{ state: 'frozen', ySplit: 1 }];
  inventorySheet.columns = [
    { key: 'category', width: 16 },
    { key: 'name', width: 38 },
    { key: 'quantity', width: 12 },
    { key: 'unit', width: 18 },
  ];

  await workbook.xlsx.writeFile(WORKBOOK_PATH);

  console.log(`Source backup: ${BACKUP_PATH}`);
  console.log(`Organized ${groupedRows.length} items in ${WORKBOOK_PATH}`);
  console.log(`Updated sheet: ${INVENTORY_SHEET}`);
  console.log('Preview:');
  for (const row of groupedRows.slice(0, 8)) {
    console.log(row.join(' | '));
  }
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
