import Foundation
import FirebaseFirestore

enum AppLanguage {
    case english
    case gujarati
}

// ── Read service ─────────────────────────────────────────────────────────────

struct GoogleSheetsInventoryService {
    private let spreadsheetEditURL = URL(string: "https://docs.google.com/spreadsheets/d/1o6njKFUu7UB-0S8eHkGJIxy6y7lN7s8_2QfO4OALzeI/edit?usp=sharing")
    private let spreadsheetBaseURL = "https://docs.google.com/spreadsheets/d/1o6njKFUu7UB-0S8eHkGJIxy6y7lN7s8_2QfO4OALzeI/gviz/tq"

    func fetchInventory(forceRefresh: Bool) async throws -> [InventoryCategory] {
        let worksheetNames = try await fetchWorksheetNames(forceRefresh: forceRefresh)

        let categories = try await withThrowingTaskGroup(of: (Int, InventoryCategory?).self) { group in
            for (index, worksheetName) in worksheetNames.enumerated() {
                group.addTask {
                    let category = try await fetchCategory(named: worksheetName, forceRefresh: forceRefresh)
                    return (index, category)
                }
            }

            var indexedCategories: [(Int, InventoryCategory)] = []
            for try await result in group {
                if let category = result.1 { indexedCategories.append((result.0, category)) }
            }

            return indexedCategories.sorted { $0.0 < $1.0 }.map(\.1)
        }

        if categories.isEmpty { throw InventoryServiceError.emptySheet }
        return categories
    }

    private func fetchWorksheetNames(forceRefresh: Bool) async throws -> [String] {
        guard let spreadsheetEditURL else { throw InventoryServiceError.invalidSheetURL }

        var request = URLRequest(url: spreadsheetEditURL)
        request.cachePolicy = forceRefresh ? .reloadIgnoringLocalCacheData : .returnCacheDataElseLoad

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw InventoryServiceError.invalidResponse
        }

        let html = String(decoding: data, as: UTF8.self)
        let pattern = #"docs-sheet-tab-caption">([^<]+)<"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsRange)

        var worksheetNames: [String] = []
        var seen = Set<String>()

        for match in matches {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let name = html[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            guard isVisibleInventoryWorksheet(name) else { continue }
            worksheetNames.append(name)
        }

        if worksheetNames.isEmpty { throw InventoryServiceError.missingWorksheets }
        return worksheetNames
    }

    private func fetchCategory(named worksheetName: String, forceRefresh: Bool) async throws -> InventoryCategory? {
        guard let rows = try await fetchRows(named: worksheetName, forceRefresh: forceRefresh) else {
            return InventoryCategory(nameEnglish: worksheetName, nameGujarati: nil, imageURL: nil, items: [])
        }

        guard let header = rows.first else {
            return InventoryCategory(nameEnglish: worksheetName, nameGujarati: nil, imageURL: nil, items: [])
        }

        let columns = header.enumerated().reduce(into: [String: Int]()) { result, entry in
            let key = entry.element.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, result[key] == nil { result[key] = entry.offset }
        }

        let nameIndex = columns["item name"] ?? columns["name"]
        let nameGujaratiIndex = columns["item name gujarati"] ?? columns["name gujarati"]
        let typeIndex = columns["type"]
        let typeGujaratiIndex = columns["type gujarati"]
        let quantityIndex = columns["stock"] ?? columns["quantity"]
        let imageURLIndex = columns["image url"] ?? columns["image_url"]
        let categoryImageURLIndex = columns["category image url"] ?? columns["category_image_url"]

        guard let nameIndex, let typeIndex, let quantityIndex else {
            throw InventoryServiceError.missingColumns
        }

        let items = rows.dropFirst().compactMap { row -> InventoryItem? in
            guard row.indices.contains(nameIndex),
                  row.indices.contains(typeIndex),
                  row.indices.contains(quantityIndex) else { return nil }

            let name = row[nameIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let type = row[typeIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let quantity = row[quantityIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let nameGujarati = nameGujaratiIndex.flatMap { row.indices.contains($0) ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            let typeGujarati = typeGujaratiIndex.flatMap { row.indices.contains($0) ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            let imageURLString = imageURLIndex.flatMap { row.indices.contains($0) ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines) : nil }

            guard !name.isEmpty else { return nil }

            return InventoryItem(
                nameEnglish: name,
                typeEnglish: type,
                quantity: quantity.isEmpty ? "0" : quantity,
                nameGujarati: normalizedOptional(nameGujarati),
                typeGujarati: normalizedOptional(typeGujarati),
                imageURL: normalizedOptional(imageURLString).flatMap(URL.init(string:))
            )
        }

        let categoryImageURL = rows.dropFirst().compactMap { row -> URL? in
            guard let categoryImageURLIndex, row.indices.contains(categoryImageURLIndex) else { return nil }
            let imageURLString = row[categoryImageURLIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizedOptional(imageURLString).flatMap(URL.init(string:))
        }.first

        return InventoryCategory(
            nameEnglish: worksheetName,
            nameGujarati: nil,
            imageURL: categoryImageURL,
            items: items
        )
    }

    private func fetchRows(named worksheetName: String, forceRefresh: Bool) async throws -> [[String]]? {
        guard var components = URLComponents(string: spreadsheetBaseURL) else {
            throw InventoryServiceError.invalidSheetURL
        }

        components.queryItems = [
            URLQueryItem(name: "tqx", value: "out:csv"),
            URLQueryItem(name: "sheet", value: worksheetName)
        ]

        guard let worksheetURL = components.url else { throw InventoryServiceError.invalidSheetURL }

        var request = URLRequest(url: worksheetURL)
        request.cachePolicy = forceRefresh ? .reloadIgnoringLocalCacheData : .returnCacheDataElseLoad

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw InventoryServiceError.invalidResponse
        }

        let csvString = String(decoding: data, as: UTF8.self)
        return CSVParser.parse(csvString)
    }

    private func isVisibleInventoryWorksheet(_ worksheetName: String) -> Bool {
        let normalizedName = worksheetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedName.isEmpty else { return false }
        guard normalizedName != "users" else { return false }
        guard !normalizedName.hasPrefix("change_") else { return false }
        return true
    }
}

// ── Write service ─────────────────────────────────────────────────────────────
//
// Writes item edits back to the Google Sheet via a Google Apps Script web app.
//
// SETUP (one-time, ~2 minutes):
//  1. Open your Google Sheet → Extensions → Apps Script.
//  2. Paste the script from AppsScript.js (included in this project).
//  3. Click Deploy → New deployment → Web app.
//     - Execute as: Me
//     - Who has access: Anyone
//  4. Copy the deployment URL (ends in /exec) and paste it below.

struct GoogleSheetsWriteService {

    // ─────────────────────────────────────────────────────────────────────────
    // TODO: Replace the empty string with your Apps Script /exec URL.
    // Example: "https://script.google.com/macros/s/AKfy.../exec"
    // ─────────────────────────────────────────────────────────────────────────
    static var appsScriptURL: String = "https://script.google.com/macros/s/AKfycbwQsZlZR5t3WDlwBqwBVxxqvrUM-RUnw-IL5syb-gaTafp4OfBKB3SherXRVDXRRVJc5Q/exec"
    static var appsScriptSecret: String = "baps-kitchen-2026-X9rPq72mLzQ4vT8s"

    func updateItem(
        worksheetName: String,
        originalName: String,
        newName: String,
        newQuantity: String,
        previousQuantity: String,
        editorName: String,
        changeWorksheetName: String,
        changeDisplayText: String,
        changeDisplayColor: String
    ) async throws {
        guard !Self.appsScriptURL.isEmpty, let url = URL(string: Self.appsScriptURL) else {
            throw WriteServiceError.notConfigured
        }

        let payload = WritePayload(
            secret: Self.appsScriptSecret,
            sheetName: worksheetName,
            originalName: originalName,
            newName: newName,
            newQuantity: newQuantity,
            previousQuantity: previousQuantity,
            editorName: editorName,
            changeSheetName: changeWorksheetName,
            changeDisplayText: changeDisplayText,
            changeDisplayColor: changeDisplayColor
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw WriteServiceError.invalidResponse
        }

        struct ScriptResponse: Decodable { let success: Bool; let error: String? }
        let result = try JSONDecoder().decode(ScriptResponse.self, from: data)
        guard result.success else {
            throw WriteServiceError.updateFailed(result.error ?? "Unknown error from Apps Script.")
        }
    }

    private struct WritePayload: Encodable {
        let secret: String
        let sheetName: String
        let originalName: String
        let newName: String
        let newQuantity: String
        let previousQuantity: String
        let editorName: String
        let changeSheetName: String
        let changeDisplayText: String
        let changeDisplayColor: String
    }
}

// ── Editor allowlist service ────────────────────────────────────────────────

struct EditorAllowlistService {
    private let database = Firestore.firestore()
    private let collectionName = "editor_allowlist"

    func isEditorAllowed(email: String) async throws -> Bool {
        let normalizedEmail = normalizedEmailKey(email)
        guard !normalizedEmail.isEmpty else { return false }

        return try await isAllowlistDocumentEnabled(id: normalizedEmail)
    }

    private func isAllowlistDocumentEnabled(id: String) async throws -> Bool {
        let snapshot = try await database.collection(collectionName).document(id).getDocument()
        guard snapshot.exists else { return false }

        if let isEnabled = snapshot.data()?["isEnabled"] as? Bool {
            return isEnabled
        }

        return true
    }
}

// ── Translation service ──────────────────────────────────────────────────────

struct GoogleTranslateService {
    func translate(categories: [InventoryCategory], to language: AppLanguage) async throws -> [InventoryCategory] {
        guard language == .gujarati else { return categories }

        let flattenedItems = categories.flatMap(\.items)
        let translatedItems = try await translate(items: flattenedItems, to: language)

        let missingCategoryTranslations = categories.filter { $0.nameGujarati?.isEmpty ?? true }
        var translatedNamesByCategoryID: [String: String] = [:]

        try await withThrowingTaskGroup(of: (String, String).self) { group in
            for category in missingCategoryTranslations {
                let categoryID = category.id
                let categoryName = category.nameEnglish
                group.addTask {
                    let translatedName = try await translate(text: categoryName, source: "en", target: "gu")
                    return (categoryID, translatedName)
                }
            }
            for try await result in group {
                translatedNamesByCategoryID[result.0] = result.1
            }
        }

        var currentIndex = 0
        return categories.map { category in
            let itemCount = category.items.count
            let translatedSlice = Array(translatedItems[currentIndex..<(currentIndex + itemCount)])
            currentIndex += itemCount
            return InventoryCategory(
                nameEnglish: category.nameEnglish,
                nameGujarati: translatedNamesByCategoryID[category.id] ?? category.nameGujarati,
                imageURL: category.imageURL,
                items: translatedSlice
            )
        }
    }

    func translate(items: [InventoryItem], to language: AppLanguage) async throws -> [InventoryItem] {
        guard language == .gujarati else { return items }

        let untranslatedItems = items.filter {
            ($0.nameGujarati?.isEmpty ?? true) || ($0.typeGujarati?.isEmpty ?? true)
        }
        guard !untranslatedItems.isEmpty else { return items }

        return try await withThrowingTaskGroup(of: (UUID, String, String).self) { group in
            for item in untranslatedItems {
                group.addTask {
                    async let translatedName = translate(text: item.nameEnglish, source: "en", target: "gu")
                    async let translatedType = translate(text: item.typeEnglish, source: "en", target: "gu")
                    return (item.id, try await translatedName, try await translatedType)
                }
            }

            var translatedValues: [UUID: (String, String)] = [:]
            for try await result in group {
                translatedValues[result.0] = (result.1, result.2)
            }

            return items.map { item in
                if let translation = translatedValues[item.id] {
                    return InventoryItem(
                        id: item.id,
                        nameEnglish: item.nameEnglish,
                        typeEnglish: item.typeEnglish,
                        quantity: item.quantity,
                        nameGujarati: translation.0,
                        typeGujarati: translation.1,
                        imageURL: item.imageURL
                    )
                }
                return item
            }
        }
    }

    private func translate(text: String, source: String, target: String) async throws -> String {
        guard var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single") else {
            throw TranslationError.invalidRequest
        }

        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]

        guard let url = components.url else { throw TranslationError.invalidRequest }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw TranslationError.invalidResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
              let sentenceGroups = json.first as? [Any] else {
            throw TranslationError.invalidPayload
        }

        let translatedText = sentenceGroups
            .compactMap { $0 as? [Any] }
            .compactMap { $0.first as? String }
            .joined()

        if translatedText.isEmpty { throw TranslationError.invalidPayload }
        return translatedText
    }
}

// ── Errors ────────────────────────────────────────────────────────────────────

enum InventoryServiceError: LocalizedError {
    case invalidSheetURL, invalidResponse, missingWorksheets, missingColumns, emptySheet

    var errorDescription: String? {
        switch self {
        case .invalidSheetURL:    return "The Google Sheet URL is invalid."
        case .invalidResponse:    return "The app could not read the Google Sheet. Make sure it is published or shared for CSV export."
        case .missingWorksheets:  return "The Google Sheet does not have any visible worksheets yet."
        case .missingColumns:     return "The Google Sheet must include Item Name, Type, and Stock columns."
        case .emptySheet:         return "No inventory items were found in the Google Sheet."
        }
    }
}

enum WriteServiceError: LocalizedError {
    case notConfigured
    case invalidResponse
    case updateFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Edit mode is not configured yet. Paste your Apps Script URL into GoogleSheetsWriteService.appsScriptURL in InventoryServices.swift."
        case .invalidResponse:
            return "The Google Sheet could not be reached. Check your network connection."
        case .updateFailed(let message):
            return "Update failed: \(message)"
        }
    }
}

enum TranslationError: LocalizedError {
    case invalidRequest, invalidResponse, invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidRequest:  return "The translation request could not be created."
        case .invalidResponse: return "The translation service is unavailable right now."
        case .invalidPayload:  return "The translation response could not be read."
        }
    }
}

func normalizedEmailKey(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

// ── CSV parser (unchanged) ────────────────────────────────────────────────────

enum CSVParser {
    static func parse(_ string: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isInsideQuotes = false

        let characters = Array(string)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if isInsideQuotes, index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\""); index += 1
                } else {
                    isInsideQuotes.toggle()
                }
            } else if character == "," && !isInsideQuotes {
                row.append(field); field = ""
            } else if character == "\n" && !isInsideQuotes {
                row.append(field); rows.append(row); row = []; field = ""
            } else if character == "\r" {
                // Ignore CR so CRLF files parse correctly.
            } else {
                field.append(character)
            }
            index += 1
        }

        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

// ── Private helpers ───────────────────────────────────────────────────────────

private func normalizedOptional(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}
