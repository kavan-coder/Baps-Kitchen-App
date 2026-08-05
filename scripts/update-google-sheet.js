const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { google } = require('googleapis');

const DOWNLOADS_DIR = '/Users/kavan_desai/Downloads';
const SERVICE_ACCOUNT_PATH = path.join(DOWNLOADS_DIR, 'service_account_key.json');
const HOST_WORKBOOK_PATH = path.join(DOWNLOADS_DIR, 'Kothar Inventory.xlsx');
const SPREADSHEET_ID = '1o6njKFUu7UB-0S8eHkGJIxy6y7lN7s8_2QfO4OALzeI';
const TARGET_SHEET_NAME = 'Inventory';
const CATEGORY_SHEETS = ['Inventory', 'Snacks', 'Farari', 'Spices'];

function xmlNodes(xml, tagName) {
  const openTag = `<${tagName}`;
  const closeTag = `</${tagName}>`;
  const selfClosing = new RegExp(`<${tagName}([^>]*)\\/?>`, 'g');
  const nodes = [];
  let match;

  while ((match = selfClosing.exec(xml)) !== null) {
    const raw = match[0];
    if (raw.endsWith('/>')) {
      nodes.push(raw);
      continue;
    }

    const start = match.index;
    const contentStart = xml.indexOf('>', start) + 1;
    const end = xml.indexOf(closeTag, contentStart);
    if (end === -1) {
      continue;
    }

    nodes.push(xml.slice(start, end + closeTag.length));
    selfClosing.lastIndex = end + closeTag.length;
  }

  return nodes;
}

function xmlAttr(node, attrName) {
  const match = node.match(new RegExp(`${attrName}="([^"]*)"`));
  return match ? match[1] : '';
}

function xmlText(node, tagName) {
  const match = node.match(new RegExp(`<${tagName}[^>]*>([\\s\\S]*?)</${tagName}>`));
  return match ? decodeXml(match[1]) : '';
}

function decodeXml(value) {
  return value
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
}

function columnNumberFromRef(cellRef) {
  const letters = (cellRef.match(/^[A-Z]+/) || [''])[0];
  let total = 0;
  for (const char of letters) {
    total = total * 26 + (char.charCodeAt(0) - 64);
  }
  return total;
}

function readZipEntry(zipPath, entryPath) {
  return execFileSync('unzip', ['-p', zipPath, entryPath], { encoding: 'utf8' });
}

function loadSharedStrings(zipPath) {
  try {
    const xml = readZipEntry(zipPath, 'xl/sharedStrings.xml');
    return xmlNodes(xml, 'si').map((node) => {
      const textParts = xmlNodes(node, 't').map((tNode) => xmlText(tNode, 't'));
      return textParts.join('');
    });
  } catch (error) {
    return [];
  }
}

function resolveWorksheetPath(zipPath, sheetName) {
  const workbookXml = readZipEntry(zipPath, 'xl/workbook.xml');
  const relsXml = readZipEntry(zipPath, 'xl/_rels/workbook.xml.rels');

  const relationships = new Map(
    xmlNodes(relsXml, 'Relationship').map((node) => [xmlAttr(node, 'Id'), xmlAttr(node, 'Target')])
  );

  const sheetNode = xmlNodes(workbookXml, 'sheet').find(
    (node) => xmlAttr(node, 'name').trim().toLowerCase() === sheetName.trim().toLowerCase()
  );

  if (!sheetNode) {
    throw new Error(`Worksheet "${sheetName}" not found in ${zipPath}.`);
  }

  const relationshipId = xmlAttr(sheetNode, 'r:id');
  const target = relationships.get(relationshipId);
  if (!target) {
    throw new Error(`Worksheet relationship "${relationshipId}" is missing.`);
  }

  return target.startsWith('xl/') ? target : `xl/${target}`;
}

function readWorksheetRows(zipPath, sheetName) {
  const sharedStrings = loadSharedStrings(zipPath);
  const worksheetPath = resolveWorksheetPath(zipPath, sheetName);
  const sheetXml = readZipEntry(zipPath, worksheetPath);
  const rowNodes = xmlNodes(sheetXml, 'row');

  return rowNodes.map((rowNode) => {
    const cellMap = new Map();

    for (const cellNode of xmlNodes(rowNode, 'c')) {
      const ref = xmlAttr(cellNode, 'r');
      const type = xmlAttr(cellNode, 't');
      const colIndex = columnNumberFromRef(ref);
      let value = '';

      if (type === 's') {
        const rawIndex = xmlText(cellNode, 'v');
        value = sharedStrings[Number(rawIndex)] || '';
      } else if (type === 'inlineStr') {
        const textNodes = xmlNodes(cellNode, 't').map((node) => xmlText(node, 't'));
        value = textNodes.join('');
      } else {
        value = xmlText(cellNode, 'v');
      }

      cellMap.set(colIndex, value);
    }

    const maxColumn = Math.max(0, ...cellMap.keys());
    return Array.from({ length: maxColumn }, (_, index) => cellMap.get(index + 1) || '');
  });
}

function normalizeHeader(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/[_\s]+/g, ' ');
}

function loadCategorySheet(sheetName) {
  const rows = readWorksheetRows(HOST_WORKBOOK_PATH, sheetName);
  if (!rows.length) {
    return [];
  }

  const headers = rows[0].map(normalizeHeader);
  const nameIndex = headers.indexOf('name');
  const quantityIndex = headers.indexOf('quantity');
  const unitIndex = headers.indexOf('unit');

  if (nameIndex === -1 || quantityIndex === -1 || unitIndex === -1) {
    throw new Error(`Sheet "${sheetName}" is missing one of the required headers: Name, Quantity, Unit.`);
  }

  return rows
    .slice(1)
    .map((row) => ({
      category: sheetName,
      name: String(row[nameIndex] || '').trim(),
      quantity: String(row[quantityIndex] || '').trim(),
      unit: String(row[unitIndex] || '').trim(),
    }))
    .filter((row) => row.name);
}

function buildInventoryRows() {
  const categoryRows = CATEGORY_SHEETS.flatMap(loadCategorySheet);
  const values = [['Category', 'Name', 'Quantity', 'Unit']];

  for (const row of categoryRows) {
    values.push([row.category, row.name, row.quantity, row.unit]);
  }

  return values;
}

async function buildSheetsClient() {
  if (!fs.existsSync(SERVICE_ACCOUNT_PATH)) {
    throw new Error(`Missing service account file at ${SERVICE_ACCOUNT_PATH}.`);
  }

  const auth = new google.auth.GoogleAuth({
    keyFile: SERVICE_ACCOUNT_PATH,
    scopes: ['https://www.googleapis.com/auth/spreadsheets'],
  });

  return google.sheets({ version: 'v4', auth: await auth.getClient() });
}

async function ensureTargetSheetExists(sheets) {
  const response = await sheets.spreadsheets.get({
    spreadsheetId: SPREADSHEET_ID,
    fields: 'sheets.properties.title',
  });

  const titles = (response.data.sheets || []).map((sheet) => sheet.properties?.title).filter(Boolean);
  if (titles.includes(TARGET_SHEET_NAME)) {
    return;
  }

  await sheets.spreadsheets.batchUpdate({
    spreadsheetId: SPREADSHEET_ID,
    requestBody: {
      requests: [
        {
          addSheet: {
            properties: {
              title: TARGET_SHEET_NAME,
            },
          },
        },
      ],
    },
  });
}

async function replaceInventoryTab(values) {
  const sheets = await buildSheetsClient();
  await ensureTargetSheetExists(sheets);

  await sheets.spreadsheets.values.clear({
    spreadsheetId: SPREADSHEET_ID,
    range: TARGET_SHEET_NAME,
  });

  const response = await sheets.spreadsheets.values.update({
    spreadsheetId: SPREADSHEET_ID,
    range: `${TARGET_SHEET_NAME}!A1`,
    valueInputOption: 'RAW',
    requestBody: {
      majorDimension: 'ROWS',
      values,
    },
  });

  const preview = await sheets.spreadsheets.values.get({
    spreadsheetId: SPREADSHEET_ID,
    range: `${TARGET_SHEET_NAME}!A1:D8`,
  });

  console.log(`Updated ${response.data.updatedRows || 0} rows on ${TARGET_SHEET_NAME}.`);
  console.log(`Updated range: ${response.data.updatedRange || 'unknown'}`);
  console.log('Preview:');
  for (const row of preview.data.values || []) {
    console.log(row.join(' | '));
  }
}

async function main() {
  if (!fs.existsSync(HOST_WORKBOOK_PATH)) {
    throw new Error(`Missing host workbook at ${HOST_WORKBOOK_PATH}.`);
  }

  const values = buildInventoryRows();
  console.log(`Prepared ${Math.max(values.length - 1, 0)} inventory rows from ${HOST_WORKBOOK_PATH}.`);

  if (process.argv.includes('--dry-run')) {
    for (const row of values.slice(0, 10)) {
      console.log(row.join(' | '));
    }
    return;
  }

  await replaceInventoryTab(values);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
