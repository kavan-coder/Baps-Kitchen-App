import Combine
import Foundation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import GoogleSignIn
import UIKit

struct InventoryEditor: Identifiable, Hashable {
    let name: String
    let email: String

    var id: String {
        normalizedSearchString(email)
    }
}

struct InventoryCategory: Identifiable, Hashable {
    let nameEnglish: String
    let nameGujarati: String?
    let imageURL: URL?
    let items: [InventoryItem]

    var id: String {
        nameEnglish
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var itemCount: Int { items.count }

    func displayName(isGujarati: Bool) -> String {
        if isGujarati, let nameGujarati, !nameGujarati.isEmpty { return nameGujarati }
        return nameEnglish
    }

    func matchesCategoryQuery(_ query: String) -> Bool {
        let normalizedQuery = normalizedSearchString(query)
        guard !normalizedQuery.isEmpty else { return false }
        return normalizedSearchString(nameEnglish).contains(normalizedQuery)
            || normalizedSearchString(nameGujarati).contains(normalizedQuery)
    }
}

struct InventoryItem: Identifiable, Hashable {
    // Explicit id so it survives local rebuilds after an edit (UUID is preserved).
    let id: UUID
    let nameEnglish: String
    let typeEnglish: String
    let quantity: String
    let nameGujarati: String?
    let typeGujarati: String?
    let imageURL: URL?

    init(
        id: UUID = UUID(),
        nameEnglish: String,
        typeEnglish: String,
        quantity: String,
        nameGujarati: String?,
        typeGujarati: String?,
        imageURL: URL?
    ) {
        self.id = id
        self.nameEnglish = nameEnglish
        self.typeEnglish = typeEnglish
        self.quantity = quantity
        self.nameGujarati = nameGujarati
        self.typeGujarati = typeGujarati
        self.imageURL = imageURL
    }

    func displayName(isGujarati: Bool) -> String {
        if isGujarati, let nameGujarati, !nameGujarati.isEmpty { return nameGujarati }
        return nameEnglish
    }

    func displayType(isGujarati: Bool) -> String {
        if isGujarati, let typeGujarati, !typeGujarati.isEmpty { return typeGujarati }
        return typeEnglish
    }

    func matchesItemQuery(_ query: String) -> Bool {
        let normalizedQuery = normalizedSearchString(query)
        guard !normalizedQuery.isEmpty else { return false }
        return normalizedSearchString(nameEnglish).contains(normalizedQuery)
            || normalizedSearchString(nameGujarati).contains(normalizedQuery)
            || normalizedSearchString(typeEnglish).contains(normalizedQuery)
            || normalizedSearchString(typeGujarati).contains(normalizedQuery)
            || normalizedSearchString(quantity).contains(normalizedQuery)
    }
}

enum InventoryUnit: String, CaseIterable, Identifiable {
    case pounds = "lbs"
    case ounces = "oz"
    case grams = "g"
    case kilograms = "kg"

    var id: String { rawValue }

    var displayName: String { rawValue }

    func pounds(from value: Double) -> Double {
        switch self {
        case .pounds: return value
        case .ounces: return value / 16
        case .grams: return value / 453.59237
        case .kilograms: return value * 2.2046226218
        }
    }

    func value(fromPounds pounds: Double) -> Double {
        switch self {
        case .pounds: return pounds
        case .ounces: return pounds * 16
        case .grams: return pounds * 453.59237
        case .kilograms: return pounds / 2.2046226218
        }
    }
}

struct InventoryQuantityParts {
    let value: Double
    let unit: String?

    var hasFixedUnit: Bool {
        unit != nil
    }

    var displayText: String {
        guard let unit else {
            return inventoryFormatQuantity(value)
        }
        return "\(inventoryFormatQuantity(value)) \(unit)"
    }
}

func parseInventoryQuantity(_ value: String) -> InventoryQuantityParts? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }

    let pattern = #"^\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*(.*?)\s*$"#
    if let regex = try? NSRegularExpression(pattern: pattern),
       let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)),
       let numberRange = Range(match.range(at: 1), in: normalized),
       let parsedValue = Double(normalized[numberRange]) {
        let unit = Range(match.range(at: 2), in: normalized)
            .map { String(normalized[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return InventoryQuantityParts(value: parsedValue, unit: unit)
    }

    let allowedCharacters = CharacterSet(charactersIn: "0123456789.-")
    let numericString = String(normalized.unicodeScalars.filter { allowedCharacters.contains($0) })
    guard !numericString.isEmpty, let parsedValue = Double(numericString) else { return nil }
    return InventoryQuantityParts(value: parsedValue, unit: nil)
}

func inventoryFormatQuantity(_ value: Double, maxFractionDigits: Int = 2) -> String {
    value.formatted(.number.precision(.fractionLength(0...maxFractionDigits)))
}

// ── View model ───────────────────────────────────────────────────────────────

@MainActor
final class InventoryViewModel: ObservableObject {
    @Published var categories: [InventoryCategory] = []
    @Published var authorizedEditor: InventoryEditor?
    @Published var isLoading = false
    @Published var isLoadingTranslation = false
    @Published var isGujaratiEnabled = false
    @Published var errorMessage: String?
    @Published var lastAttemptedEditorEmail: String?

    private let spreadsheetService = GoogleSheetsInventoryService()
    private let translator = GoogleTranslateService()
    private let writeService = GoogleSheetsWriteService()
    private let editorAllowlistService = EditorAllowlistService()
    private var authStateDidChangeHandle: AuthStateDidChangeListenerHandle?

    init() {
        authStateDidChangeHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                await self?.handleAuthStateChange(user)
            }
        }

        Task {
            await handleAuthStateChange(Auth.auth().currentUser)
        }
    }

    deinit {
        if let authStateDidChangeHandle {
            Auth.auth().removeStateDidChangeListener(authStateDidChangeHandle)
        }
    }

    var isEditorAuthenticated: Bool {
        authorizedEditor != nil
    }

    // ── Read ─────────────────────────────────────────────────────────────────

    func loadInventory(forceRefresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        do {
            categories = try await spreadsheetService.fetchInventory(forceRefresh: forceRefresh)
        } catch {
            if categories.isEmpty { categories = InventoryCategory.sampleData }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func toggleTranslation() async {
        if isGujaratiEnabled { isGujaratiEnabled = false; return }

        let missingCategory = categories.contains { $0.nameGujarati?.isEmpty ?? true }
        let missingItem = categories.contains { cat in
            cat.items.contains { ($0.nameGujarati?.isEmpty ?? true) || ($0.typeGujarati?.isEmpty ?? true) }
        }
        guard missingCategory || missingItem else { isGujaratiEnabled = true; return }

        isLoadingTranslation = true
        errorMessage = nil
        do {
            categories = try await translator.translate(categories: categories, to: .gujarati)
            isGujaratiEnabled = true
        } catch {
            errorMessage = "Translation failed. Showing English instead."
            isGujaratiEnabled = false
        }
        isLoadingTranslation = false
    }

    func searchDestination(for query: String) -> InventorySearchDestination? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let exact = categories.first(where: { $0.matchesCategoryQuery(trimmed) && exactMatch(query: trimmed, against: [$0.nameEnglish, $0.nameGujarati]) }) {
            return .category(categoryID: exact.id, highlightedItemID: nil)
        }
        for category in categories {
            if let exact = category.items.first(where: { exactMatch(query: trimmed, against: [$0.nameEnglish, $0.nameGujarati, $0.typeEnglish, $0.typeGujarati, $0.quantity]) }) {
                return .category(categoryID: category.id, highlightedItemID: exact.id)
            }
        }
        if let cat = categories.first(where: { $0.matchesCategoryQuery(trimmed) }) {
            return .category(categoryID: cat.id, highlightedItemID: nil)
        }
        for category in categories {
            if let item = category.items.first(where: { $0.matchesItemQuery(trimmed) }) {
                return .category(categoryID: category.id, highlightedItemID: item.id)
            }
        }

        if let nearby = nearbySearchDestination(for: trimmed) {
            return nearby
        }

        return nil
    }

    func autocompleteSuggestions(for query: String, limit: Int = 5) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var seen = Set<String>()
        var suggestions: [InventoryAutocompleteSuggestion] = []

        func addSuggestion(_ value: String?, rank: Int) {
            guard let value else { return }
            let displayText = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayText.isEmpty else { return }

            let normalizedValue = normalizedSearchString(displayText)
            let normalizedQuery = normalizedSearchString(trimmed)
            guard !normalizedValue.isEmpty, normalizedValue != normalizedQuery else { return }

            let score = autocompleteSuggestionScore(query: trimmed, value: displayText)
            guard score >= 450, seen.insert(normalizedValue).inserted else { return }
            suggestions.append(
                InventoryAutocompleteSuggestion(
                    text: displayText,
                    score: score,
                    rank: rank
                )
            )
        }

        for category in categories {
            addSuggestion(category.nameEnglish, rank: 0)
            addSuggestion(category.nameGujarati, rank: 0)

            for item in category.items {
                addSuggestion(item.nameEnglish, rank: 1)
                addSuggestion(item.nameGujarati, rank: 1)
                addSuggestion(item.typeEnglish, rank: 2)
                addSuggestion(item.typeGujarati, rank: 2)
            }
        }

        return suggestions
            .sorted {
                if abs($0.score - $1.score) > 0.0001 {
                    return $0.score > $1.score
                }
                if $0.rank != $1.rank {
                    return $0.rank < $1.rank
                }
                return $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending
            }
            .prefix(limit)
            .map(\.text)
    }

    func logoutEditor() {
        do {
            try Auth.auth().signOut()
            authorizedEditor = nil
            lastAttemptedEditorEmail = nil
        } catch {
            errorMessage = "Unable to sign out right now."
        }
    }

    func signInWithGoogle(presentingViewController: UIViewController) async throws -> Bool {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw InventoryAuthorizationError.googleSignInUnavailable
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        let result: GIDSignInResult
        do {
            result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController)
        } catch {
            throw InventoryAuthorizationError.googleSignInFailed(error.localizedDescription)
        }

        lastAttemptedEditorEmail = trimmedNonEmpty(result.user.profile?.email)

        guard let idToken = result.user.idToken?.tokenString else {
            throw InventoryAuthorizationError.googleSignInFailed()
        }

        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )

        do {
            let authResult = try await Auth.auth().signIn(with: credential)
            lastAttemptedEditorEmail = trimmedNonEmpty(authResult.user.email) ?? lastAttemptedEditorEmail
            try await authorizeEditor(authResult.user)
        } catch {
            if error is InventoryAuthorizationError {
                throw error
            }
            throw InventoryAuthorizationError.googleSignInFailed(error.localizedDescription)
        }

        return true
    }

    // ── Write ─────────────────────────────────────────────────────────────────

    /// Updates a single item's name and quantity both in the Google Sheet and locally.
    func updateItem(
        in category: InventoryCategory,
        item: InventoryItem,
        newName: String,
        enteredQuantity: String,
        enteredUnit: InventoryUnit,
        fixedUnit: String? = nil
    ) async throws {
        guard let authorizedEditor else {
            throw InventoryAuthorizationError.notAuthenticated
        }

        let finalName = newName.isEmpty ? item.nameEnglish : newName
        guard let enteredQuantityValue = parseInventoryQuantity(enteredQuantity)?.value else {
            throw WriteServiceError.updateFailed("Enter a valid quantity.")
        }

        let trimmedFixedUnit = fixedUnit?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFixedUnit = (trimmedFixedUnit?.isEmpty == false) ? trimmedFixedUnit : nil

        let finalQuantity: String
        let unitDelta: Double
        let changeDisplayText: String
        if let normalizedFixedUnit {
            finalQuantity = "\(formatQuantity(enteredQuantityValue)) \(normalizedFixedUnit)"
            let previousQuantityValue = parseInventoryQuantity(item.quantity)?.value ?? 0
            unitDelta = enteredQuantityValue - previousQuantityValue
            changeDisplayText = formatSignedQuantity(unitDelta, unitText: normalizedFixedUnit)
        } else {
            let finalQuantityPounds = enteredUnit.pounds(from: enteredQuantityValue)
            finalQuantity = formatQuantity(finalQuantityPounds)
            let previousQuantityPounds = parseInventoryQuantity(item.quantity)?.value ?? 0
            unitDelta = enteredUnit.value(fromPounds: finalQuantityPounds - previousQuantityPounds)
            changeDisplayText = formatSignedQuantity(unitDelta, unit: enteredUnit)
        }
        let changeDisplayColor = unitDelta > 0 ? "#1b8f3a" : (unitDelta < 0 ? "#c62828" : "#444444")

        // Write to Google Sheet via Apps Script
        try await writeService.updateItem(
            worksheetName: category.nameEnglish,
            originalName: item.nameEnglish,
            newName: finalName,
            newQuantity: finalQuantity,
            previousQuantity: item.quantity,
            editorName: authorizedEditor.name,
            changeWorksheetName: "Change_\(category.nameEnglish)",
            changeDisplayText: changeDisplayText,
            changeDisplayColor: changeDisplayColor
        )

        // Update local state immediately so the UI reflects the change without a full reload.
        categories = categories.map { cat in
            guard cat.id == category.id else { return cat }
            let updatedItems = cat.items.map { existing -> InventoryItem in
                guard existing.id == item.id else { return existing }
                return InventoryItem(
                    id: existing.id,           // preserve identity
                    nameEnglish: finalName,
                    typeEnglish: existing.typeEnglish,
                    quantity: finalQuantity,
                    nameGujarati: existing.nameGujarati,
                    typeGujarati: existing.typeGujarati,
                    imageURL: existing.imageURL
                )
            }
            return InventoryCategory(
                nameEnglish: cat.nameEnglish,
                nameGujarati: cat.nameGujarati,
                imageURL: cat.imageURL,
                items: updatedItems
            )
        }
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private func formatQuantity(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }

    private func formatSignedQuantity(_ value: Double, unit: InventoryUnit) -> String {
        formatSignedQuantity(value, unitText: unit.displayName)
    }

    private func formatSignedQuantity(_ value: Double, unitText: String) -> String {
        let formattedMagnitude = abs(value).formatted(.number.precision(.fractionLength(0...2)))
        if value > 0 {
            return "+\(formattedMagnitude) \(unitText)"
        }
        if value < 0 {
            return "-\(formattedMagnitude) \(unitText)"
        }
        return "0 \(unitText)"
    }

    private func exactMatch(query: String, against values: [String?]) -> Bool {
        let normalizedQuery = normalizedSearchString(query)
        return values.contains { normalizedSearchString($0) == normalizedQuery }
    }

    private func nearbySearchDestination(for query: String) -> InventorySearchDestination? {
        let categoryResults = categories.compactMap { category -> InventorySearchResult? in
            let score = proximitySearchScore(
                query: query,
                values: [category.nameEnglish, category.nameGujarati]
            )
            guard score >= 450 else { return nil }
            return InventorySearchResult(
                score: score,
                rank: 1,
                destination: .category(categoryID: category.id, highlightedItemID: nil)
            )
        }

        let itemResults = categories.flatMap { category in
            category.items.compactMap { item -> InventorySearchResult? in
                let score = proximitySearchScore(
                    query: query,
                    values: [
                        item.nameEnglish,
                        item.nameGujarati,
                        item.typeEnglish,
                        item.typeGujarati,
                        item.quantity
                    ]
                )
                guard score >= 450 else { return nil }
                return InventorySearchResult(
                    score: score,
                    rank: 0,
                    destination: .category(categoryID: category.id, highlightedItemID: item.id)
                )
            }
        }

        return (categoryResults + itemResults)
            .sorted {
                if abs($0.score - $1.score) > 0.0001 {
                    return $0.score > $1.score
                }
                return $0.rank < $1.rank
            }
            .first?
            .destination
    }

    private func handleAuthStateChange(_ user: User?) async {
        guard let user else {
            authorizedEditor = nil
            return
        }

        do {
            try await authorizeEditor(user)
        } catch let authError as InventoryAuthorizationError {
            authorizedEditor = nil
            errorMessage = accessDeniedMessage(for: authError)
        } catch {
            authorizedEditor = nil
            errorMessage = accessDeniedMessage()
        }
    }

    private func authorizeEditor(_ user: User) async throws {
        guard let email = trimmedNonEmpty(user.email) else {
            try? Auth.auth().signOut()
            authorizedEditor = nil
            throw InventoryAuthorizationError.missingEmail
        }

        let isAllowed: Bool
        do {
            isAllowed = try await editorAllowlistService.isEditorAllowed(email: email)
        } catch {
            authorizedEditor = nil
            throw InventoryAuthorizationError.allowlistUnavailable(Self.allowlistErrorMessage(from: error))
        }

        guard isAllowed else {
            try? Auth.auth().signOut()
            authorizedEditor = nil
            throw InventoryAuthorizationError.unauthorizedEditor(email)
        }

        let displayName = trimmedNonEmpty(user.displayName) ?? email
        authorizedEditor = InventoryEditor(name: displayName, email: email)
        lastAttemptedEditorEmail = email
    }

    private func syncAuthorizedEditor(with user: User?) {
        guard let user, let email = trimmedNonEmpty(user.email) else {
            authorizedEditor = nil
            return
        }

        let displayName = trimmedNonEmpty(user.displayName) ?? email
        authorizedEditor = InventoryEditor(name: displayName, email: email)
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func accessDeniedMessage(for error: Error? = nil) -> String {
        if let authError = error as? InventoryAuthorizationError,
           case let .unauthorizedEditor(email) = authError {
            return "\(email) doesn't have access to edit mode"
        }

        if let email = lastAttemptedEditorEmail, !email.isEmpty {
            return "\(email) doesn't have access to edit mode"
        }

        return "This account doesn't have access to edit mode"
    }

    private static func allowlistErrorMessage(from error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            switch code {
            case .permissionDenied:
                return "Firestore denied access to the editor allowlist. Check your Firestore rules for the editor_allowlist collection."
            case .notFound:
                return "The Firestore database for this Firebase project hasn't been set up yet."
            case .unavailable:
                return "Firestore is temporarily unavailable. Please try again in a moment."
            default:
                break
            }
        }

        return error.localizedDescription
    }
}

// ── Sample data ──────────────────────────────────────────────────────────────

extension InventoryCategory {
    static let sampleData: [InventoryCategory] = [
        InventoryCategory(
            nameEnglish: "Vegetables",
            nameGujarati: "શાકભાજી",
            imageURL: nil,
            items: [
                InventoryItem(nameEnglish: "Tomatoes", typeEnglish: "Vegetable", quantity: "18", nameGujarati: "ટામેટાં", typeGujarati: "શાકભાજી", imageURL: nil),
                InventoryItem(nameEnglish: "Potatoes", typeEnglish: "Vegetable", quantity: "24", nameGujarati: "બટાકા", typeGujarati: "શાકભાજી", imageURL: nil)
            ]
        ),
        InventoryCategory(
            nameEnglish: "Pantry",
            nameGujarati: "ભંડાર",
            imageURL: nil,
            items: [
                InventoryItem(nameEnglish: "Rice", typeEnglish: "Grain", quantity: "42", nameGujarati: "ચોખા", typeGujarati: "અનાજ", imageURL: nil),
                InventoryItem(nameEnglish: "Mangoes", typeEnglish: "Fruit", quantity: "24", nameGujarati: "કેરી", typeGujarati: "ફળ", imageURL: nil)
            ]
        )
    ]
}

// ── Search destination ────────────────────────────────────────────────────────

enum InventorySearchDestination: Hashable {
    case category(categoryID: String, highlightedItemID: UUID?)
}

private struct InventorySearchResult {
    let score: Double
    let rank: Int
    let destination: InventorySearchDestination
}

private struct InventoryAutocompleteSuggestion {
    let text: String
    let score: Double
    let rank: Int
}

enum InventoryAuthorizationError: LocalizedError {
    case notAuthenticated
    case googleSignInUnavailable
    case googleSignInFailed(String? = nil)
    case missingEmail
    case unauthorizedEditor(String)
    case allowlistUnavailable(String? = nil)

    var errorDescription: String? {
        "(email) doesn't have access to edit mode"
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

private func normalizedSearchString(_ value: String?) -> String {
    guard let value else { return "" }
    return value
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private func proximitySearchScore(query: String, values: [String?]) -> Double {
    values.map { proximitySearchScore(query: query, value: $0) }.max() ?? 0
}

private func autocompleteSuggestionScore(query: String, value: String) -> Double {
    let normalizedQuery = normalizedSearchString(query)
    let normalizedValue = normalizedSearchString(value)
    guard !normalizedQuery.isEmpty, !normalizedValue.isEmpty else { return 0 }

    if normalizedValue.hasPrefix(normalizedQuery) { return 980 }
    if normalizedValue.contains(normalizedQuery) { return 900 }

    let queryTokens = searchTokens(normalizedQuery)
    let valueTokens = searchTokens(normalizedValue)

    if let firstValueToken = valueTokens.first, firstValueToken.hasPrefix(normalizedQuery) {
        return 940
    }

    if queryTokens.count == 1, let queryToken = queryTokens.first {
        let bestTokenScore = valueTokens.map { tokenScore(query: queryToken, candidate: $0) }.max() ?? 0
        return bestTokenScore
    }

    return proximitySearchScore(query: query, value: value)
}

private func proximitySearchScore(query: String, value: String?) -> Double {
    let normalizedQuery = normalizedSearchString(query)
    let normalizedValue = normalizedSearchString(value)
    guard !normalizedQuery.isEmpty, !normalizedValue.isEmpty else { return 0 }

    if normalizedValue == normalizedQuery { return 1_000 }
    if normalizedValue.contains(normalizedQuery) {
        let coverage = Double(normalizedQuery.count) / Double(max(normalizedValue.count, 1))
        return 850 + (100 * coverage)
    }

    let queryTokens = searchTokens(normalizedQuery)
    let valueTokens = searchTokens(normalizedValue)
    guard !queryTokens.isEmpty, !valueTokens.isEmpty else { return 0 }

    if queryTokens.count == 1, let queryToken = queryTokens.first {
        return valueTokens.map { tokenScore(query: queryToken, candidate: $0) }.max() ?? 0
    }

    let orderedTokenScore = orderedProximityScore(queryTokens: queryTokens, valueTokens: valueTokens)
    let fuzzyTokenScore = fuzzyTokenCoverageScore(queryTokens: queryTokens, valueTokens: valueTokens)
    return max(orderedTokenScore, fuzzyTokenScore)
}

private func searchTokens(_ value: String) -> [String] {
    value
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
        .filter { !$0.isEmpty }
}

private func orderedProximityScore(queryTokens: [String], valueTokens: [String]) -> Double {
    var matchIndexes: [Int] = []
    var searchStart = 0

    for queryToken in queryTokens {
        guard let matchIndex = valueTokens[searchStart...].firstIndex(where: {
            $0 == queryToken || $0.hasPrefix(queryToken)
        }) else {
            return 0
        }
        matchIndexes.append(matchIndex)
        searchStart = min(matchIndex + 1, valueTokens.count)
    }

    guard let first = matchIndexes.first, let last = matchIndexes.last else { return 0 }
    let span = last - first + 1
    let gapPenalty = max(0, span - queryTokens.count) * 25
    return max(0, 820 - Double(gapPenalty))
}

private func fuzzyTokenCoverageScore(queryTokens: [String], valueTokens: [String]) -> Double {
    var usedIndexes = Set<Int>()
    var totalScore = 0.0

    for queryToken in queryTokens {
        let scoredTokens = valueTokens.enumerated()
            .filter { !usedIndexes.contains($0.offset) }
            .map { (index: $0.offset, score: tokenScore(query: queryToken, candidate: $0.element)) }
            .sorted { $0.score > $1.score }

        guard let best = scoredTokens.first, best.score >= 520 else {
            return 0
        }

        usedIndexes.insert(best.index)
        totalScore += best.score
    }

    return totalScore / Double(queryTokens.count)
}

private func tokenScore(query: String, candidate: String) -> Double {
    guard !query.isEmpty, !candidate.isEmpty else { return 0 }
    if candidate == query { return 800 }
    if candidate.hasPrefix(query) { return 760 }
    if candidate.contains(query) { return 700 }

    let similarity = stringSimilarity(query, candidate)
    guard similarity >= 0.68 else { return 0 }
    return 520 + (160 * similarity)
}

private func stringSimilarity(_ lhs: String, _ rhs: String) -> Double {
    let maxLength = max(lhs.count, rhs.count)
    guard maxLength > 0 else { return 1 }
    let distance = levenshteinDistance(lhs, rhs)
    return 1 - (Double(distance) / Double(maxLength))
}

private func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
    let lhsChars = Array(lhs)
    let rhsChars = Array(rhs)
    guard !lhsChars.isEmpty else { return rhsChars.count }
    guard !rhsChars.isEmpty else { return lhsChars.count }

    var previousRow = Array(0...rhsChars.count)
    var currentRow = Array(repeating: 0, count: rhsChars.count + 1)

    for lhsIndex in 1...lhsChars.count {
        currentRow[0] = lhsIndex

        for rhsIndex in 1...rhsChars.count {
            let deletion = previousRow[rhsIndex] + 1
            let insertion = currentRow[rhsIndex - 1] + 1
            let substitution = previousRow[rhsIndex - 1] + (lhsChars[lhsIndex - 1] == rhsChars[rhsIndex - 1] ? 0 : 1)
            currentRow[rhsIndex] = min(deletion, insertion, substitution)
        }

        swap(&previousRow, &currentRow)
    }

    return previousRow[rhsChars.count]
}
