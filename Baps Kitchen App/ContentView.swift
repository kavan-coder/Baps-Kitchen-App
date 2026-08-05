import SwiftUI
import FirebaseAI

// ── Root content view ────────────────────────────────────────────────────────

struct ContentView: View {
    let isEditMode: Bool
    var onGoHome: (() -> Void)? = nil
    
    // Accept the ViewModel from HomeView instead of creating a new one
    @ObservedObject var viewModel: InventoryViewModel
    @Environment(\.dismiss) private var dismiss

    let model = FirebaseAI.firebaseAI(backend: .googleAI())
        .generativeModel(modelName: "gemini-2.5-flash")

    @State private var searchText = ""
    @State private var searchFeedback: String?
    @State private var navigationPath = NavigationPath()
    @State private var selectedCategoryID: String?
    @State private var selectedHighlightedItemID: UUID?

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                backgroundGradient.ignoresSafeArea()

                Group {
                    if viewModel.isLoading && viewModel.categories.isEmpty {
                        ProgressView("Loading categories…")
                            .tint(.brown)
                    } else if let errorMessage = viewModel.errorMessage, viewModel.categories.isEmpty {
                        ContentUnavailableView(
                            "Unable to Load Categories",
                            systemImage: "tray.full",
                            description: Text(errorMessage)
                        )
                    } else {
                        VStack(spacing: 0) {
                            GlassTopBar(
                                title: "Inventory",
                                showsBackButton: true,
                                isRefreshDisabled: viewModel.isLoading,
                                translateTitle: viewModel.isGujaratiEnabled ? "English" : "Gujarati",
                                isTranslateDisabled: viewModel.isLoadingTranslation,
                                onBack: goHome,
                                onRefresh: {
                                    Task { await viewModel.loadInventory(forceRefresh: true) }
                                },
                                onTranslate: {
                                    Task { await viewModel.toggleTranslation() }
                                }
                            )

                            PinnedSearchHeader {
                                UniversalSearchBar(
                                    text: $searchText,
                                    feedback: searchFeedback,
                                    suggestions: viewModel.autocompleteSuggestions(for: searchText),
                                    onSubmit: { runSearch() },
                                    onSuggestionSelected: runSearch
                                )
                            }

                            NavigationLink(
                                destination: searchDestinationView,
                                isActive: searchNavigationBinding
                            ) {
                                EmptyView()
                            }
                            .hidden()
                            .frame(width: 0, height: 0)

                            ScrollView {
                                VStack(spacing: 20) {
                                    if isEditMode {
                                        EditModeBanner()
                                    }

                                    LazyVGrid(columns: columns, spacing: 16) {
                                        ForEach(viewModel.categories) { category in
                                            NavigationLink {
                                                CategoryItemsView(
                                                    categoryID: category.id,
                                                    highlightedItemID: nil,
                                                    isEditMode: isEditMode,
                                                    viewModel: viewModel
                                                )
                                            } label: {
                                                CategoryCard(
                                                    category: category,
                                                    isGujarati: viewModel.isGujaratiEnabled
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .padding(.top, 8)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 24)
                            }
                            .refreshable {
                                await viewModel.loadInventory(forceRefresh: true)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Inventory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func goHome() {
        if let onGoHome {
            onGoHome()
        } else {
            dismiss()
        }
    }

    private func runSearch(_ query: String? = nil) {
        guard !viewModel.isLoading else { return }
        let trimmed = (query ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchFeedback = "Type a category or item to search."
            return
        }
        if let destination = viewModel.searchDestination(for: trimmed) {
            searchFeedback = nil
            switch destination {
            case .category(let categoryID, let highlightedItemID):
                selectedCategoryID = categoryID
                selectedHighlightedItemID = highlightedItemID
            }
        } else {
            searchFeedback = "No category or item matched \"\(trimmed)\"."
        }
        searchText = ""
    }

    @ViewBuilder
    private var searchDestinationView: some View {
        if let selectedCategoryID {
            CategoryItemsView(
                categoryID: selectedCategoryID,
                highlightedItemID: selectedHighlightedItemID,
                isEditMode: isEditMode,
                viewModel: viewModel
            )
        } else {
            EmptyView()
        }
    }

    private var searchNavigationBinding: Binding<Bool> {
        Binding(
            get: { selectedCategoryID != nil },
            set: { isActive in
                if !isActive {
                    selectedCategoryID = nil
                    selectedHighlightedItemID = nil
                }
            }
        )
    }
}

// ── Edit mode banner ─────────────────────────────────────────────────────────

private struct EditModeBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.circle.fill")
                .font(.system(size: 16, weight: .semibold))
            Text("Edit Mode — tap any item to update it")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(Color(red: 0.55, green: 0.30, blue: 0.06))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 1.0, green: 0.88, blue: 0.66))
        )
    }
}

// ── Search bar ───────────────────────────────────────────────────────────────

private struct PinnedSearchHeader<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 14)
    }
}

private struct LiquidGlassPanel<S: Shape>: View {
    let shape: S

    var body: some View {
        if #available(iOS 26.0, *) {
            shape
                .fill(Color.white.opacity(0.001))
                .glassEffect(.clear.interactive(), in: shape)
        } else {
            shape
                .fill(Color.white.opacity(0.74))
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(Color.white.opacity(0.45), lineWidth: 1)
                }
        }
    }
}

private struct GlassTopBar: View {
    private enum Metrics {
        static let controlHeight: CGFloat = 48
        static let iconSize: CGFloat = 22
        static let titleSidePaddingWithBack: CGFloat = 116
        static let titleSidePaddingWithoutBack: CGFloat = 96
    }

    let title: String
    let showsBackButton: Bool
    let isRefreshDisabled: Bool
    let translateTitle: String
    let isTranslateDisabled: Bool
    let onBack: () -> Void
    let onRefresh: () -> Void
    let onTranslate: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                if showsBackButton {
                    GlassIconButton(
                        systemName: "chevron.left",
                        size: Metrics.controlHeight,
                        iconSize: Metrics.iconSize,
                        action: onBack
                    )
                }

                GlassIconButton(
                    systemName: "arrow.clockwise",
                    size: Metrics.controlHeight,
                    iconSize: Metrics.iconSize,
                    action: onRefresh
                )
                    .disabled(isRefreshDisabled)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.24, green: 0.17, blue: 0.08))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .padding(.horizontal, showsBackButton ? Metrics.titleSidePaddingWithBack : Metrics.titleSidePaddingWithoutBack)
                .frame(maxWidth: .infinity)

            Button(action: onTranslate) {
                Text(translateTitle)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .padding(.horizontal, 18)
                    .frame(height: Metrics.controlHeight)
                    .background(
                        LiquidGlassPanel(shape: Capsule(style: .continuous))
                    )
            }
            .buttonStyle(.plain)
            .disabled(isTranslateDisabled)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}

private struct GlassIconButton: View {
    let systemName: String
    var size: CGFloat = 48
    var iconSize: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.black)
                .frame(width: size, height: size)
                .background(
                    LiquidGlassPanel(shape: Circle())
                )
        }
        .buttonStyle(.plain)
    }
}

private struct DetailGlassTopBar: View {
    let title: String
    let isRefreshDisabled: Bool
    let onBack: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        ZStack {
            GlassIconButton(systemName: "chevron.left", action: onBack)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.24, green: 0.17, blue: 0.08))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .padding(.horizontal, 72)
                .frame(maxWidth: .infinity)

            GlassIconButton(systemName: "arrow.clockwise", action: onRefresh)
                .disabled(isRefreshDisabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}

private struct UniversalSearchBar: View {
    @Binding var text: String
    let feedback: String?
    let suggestions: [String]
    let onSubmit: () -> Void
    let onSuggestionSelected: (String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.53, green: 0.42, blue: 0.28))

                TextField("Search categories or items", text: $text)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .foregroundStyle(.black)
                    .tint(.black)
                    .submitLabel(.search)
                    .onSubmit(onSubmit)

                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.brown.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onSubmit) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color(red: 0.60, green: 0.43, blue: 0.20))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(
                LiquidGlassPanel(shape: RoundedRectangle(cornerRadius: 28, style: .continuous))
            )

            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                        Button {
                            text = suggestion
                            onSuggestionSelected(suggestion)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.60, green: 0.43, blue: 0.20))

                                Text(suggestion)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color(red: 0.24, green: 0.17, blue: 0.08))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)

                                Spacer()

                                Image(systemName: "arrow.up.left")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color(red: 0.60, green: 0.43, blue: 0.20).opacity(0.75))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                        }
                        .buttonStyle(.plain)

                        if index < suggestions.count - 1 {
                            Divider()
                                .padding(.leading, 39)
                                .padding(.trailing, 14)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(red: 0.78, green: 0.60, blue: 0.38).opacity(0.28), lineWidth: 1)
                }
            }

            if let feedback, !feedback.isEmpty {
                Text(feedback)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.58, green: 0.34, blue: 0.18))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
        }
    }
}

// ── Inventory card ───────────────────────────────────────────────────────────

private struct InventoryCard: View {
    let item: InventoryItem
    let isGujarati: Bool
    var isEditMode: Bool = false

    var body: some View {
        DepthCardContainer(height: 230) {
            VStack(alignment: .center, spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    ItemImageView(item: item, height: 102, cornerRadius: 18)

                    if isEditMode {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color(red: 0.78, green: 0.46, blue: 0.16))
                            .background(Circle().fill(.white).padding(3))
                            .offset(x: 6, y: -6)
                    }
                }

                VStack(alignment: .center, spacing: 6) {
                    Text(item.displayName(isGujarati: isGujarati))
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.18, green: 0.15, blue: 0.13))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)

                    Text(item.displayType(isGujarati: isGujarati))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.45, green: 0.37, blue: 0.30))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox.fill")
                            .foregroundStyle(Color(red: 0.67, green: 0.48, blue: 0.29))

                        Text("Qty: \(inventoryQuantityWithPoundsUnit(item.quantity))")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.38, green: 0.28, blue: 0.18))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 0)
            }
        }
        .overlay {
            if isEditMode {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(red: 0.78, green: 0.46, blue: 0.16).opacity(0.45), lineWidth: 2)
                    .padding(1)
            }
        }
    }
}

// ── Category card ────────────────────────────────────────────────────────────

private struct CategoryCard: View {
    let category: InventoryCategory
    let isGujarati: Bool

    var body: some View {
        DepthCardContainer(height: 220) {
            VStack(alignment: .center, spacing: 12) {
                CategoryPreviewView(category: category)

                VStack(alignment: .center, spacing: 6) {
                    Text(category.displayName(isGujarati: isGujarati))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.18, green: 0.15, blue: 0.13))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)

                    Text("\(category.itemCount) items")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.45, green: 0.37, blue: 0.30))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if let sampleItem = category.items.first {
                        Text(sampleItem.displayType(isGujarati: isGujarati))
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color(red: 0.60, green: 0.47, blue: 0.34))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 0)
            }
        }
    }
}

// ── Category items view ──────────────────────────────────────────────────────

private struct CategoryItemsView: View {
    let categoryID: String
    let highlightedItemID: UUID?
    let isEditMode: Bool
    @ObservedObject var viewModel: InventoryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var editingItem: InventoryItem?
    @State private var searchText = ""
    @State private var searchFeedback: String?
    @State private var selectedCategoryID: String?
    @State private var selectedHighlightedItemID: UUID?

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    private var category: InventoryCategory? {
        viewModel.categories.first { $0.id == categoryID }
    }

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()

            if let category {
                if category.items.isEmpty {
                    ContentUnavailableView(
                        "No Items Yet",
                        systemImage: "shippingbox",
                        description: Text("Add rows to this worksheet to fill the category.")
                    )
                } else {
                    VStack(spacing: 0) {
                        GlassTopBar(
                            title: category.displayName(isGujarati: viewModel.isGujaratiEnabled),
                            showsBackButton: true,
                            isRefreshDisabled: viewModel.isLoading,
                            translateTitle: viewModel.isGujaratiEnabled ? "English" : "Gujarati",
                            isTranslateDisabled: viewModel.isLoadingTranslation,
                            onBack: { dismiss() },
                            onRefresh: {
                                Task { await viewModel.loadInventory(forceRefresh: true) }
                            },
                            onTranslate: {
                                Task { await viewModel.toggleTranslation() }
                            }
                        )

                        PinnedSearchHeader {
                                UniversalSearchBar(
                                    text: $searchText,
                                    feedback: searchFeedback,
                                    suggestions: viewModel.autocompleteSuggestions(for: searchText),
                                    onSubmit: { runSearch() },
                                    onSuggestionSelected: runSearch
                                )
                            }

                        NavigationLink(
                            destination: searchDestinationView,
                            isActive: searchNavigationBinding
                        ) {
                            EmptyView()
                        }
                        .hidden()
                        .frame(width: 0, height: 0)

                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 20) {
                                    if isEditMode {
                                        EditModeBanner()
                                    }

                                    LazyVGrid(columns: columns, spacing: 16) {
                                        ForEach(category.items) { item in
                                            if isEditMode {
                                                Button {
                                                    editingItem = item
                                                } label: {
                                                    InventoryCard(
                                                        item: item,
                                                        isGujarati: viewModel.isGujaratiEnabled,
                                                        isEditMode: true
                                                    )
                                                    .highlightedBorder(item.id == highlightedItemID)
                                                }
                                                .buttonStyle(.plain)
                                                .id(item.id)
                                            } else {
                                                NavigationLink {
                                                    InventoryDetailView(item: item, viewModel: viewModel)
                                                } label: {
                                                    InventoryCard(
                                                        item: item,
                                                        isGujarati: viewModel.isGujaratiEnabled,
                                                        isEditMode: false
                                                    )
                                                    .highlightedBorder(item.id == highlightedItemID)
                                                }
                                                .buttonStyle(.plain)
                                                .id(item.id)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .padding(.top, 8)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 24)
                            }
                            .onAppear {
                                guard let highlightedItemID else { return }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    withAnimation(.easeInOut(duration: 0.35)) {
                                        proxy.scrollTo(highlightedItemID, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Category Unavailable",
                    systemImage: "square.grid.2x2",
                    description: Text("Refresh the inventory to reload the worksheet list.")
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(category?.displayName(isGujarati: viewModel.isGujaratiEnabled) ?? "Category")
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $editingItem) { item in
            if let category {
                EditItemSheet(item: item, category: category, viewModel: viewModel)
            }
        }
    }

    private func runSearch(_ query: String? = nil) {
        guard !viewModel.isLoading else { return }
        let trimmed = (query ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchFeedback = "Type a category or item to search."
            return
        }
        if let destination = viewModel.searchDestination(for: trimmed) {
            searchFeedback = nil
            switch destination {
            case .category(let categoryID, let highlightedItemID):
                selectedCategoryID = categoryID
                selectedHighlightedItemID = highlightedItemID
            }
        } else {
            searchFeedback = "No category or item matched \"\(trimmed)\"."
        }
        searchText = ""
    }

    @ViewBuilder
    private var searchDestinationView: some View {
        if let selectedCategoryID {
            CategoryItemsView(
                categoryID: selectedCategoryID,
                highlightedItemID: selectedHighlightedItemID,
                isEditMode: isEditMode,
                viewModel: viewModel
            )
        } else {
            EmptyView()
        }
    }

    private var searchNavigationBinding: Binding<Bool> {
        Binding(
            get: { selectedCategoryID != nil },
            set: { isActive in
                if !isActive {
                    selectedCategoryID = nil
                    selectedHighlightedItemID = nil
                }
            }
        )
    }
}

// ── Edit item sheet ──────────────────────────────────────────────────────────

private struct EditItemSheet: View {
    let item: InventoryItem
    let category: InventoryCategory
    @ObservedObject var viewModel: InventoryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var editedName: String
    @State private var editedQuantity: String
    @State private var selectedUnit: InventoryUnit = .pounds
    @State private var isSaving = false
    @State private var saveError: String?

    private var fixedUnit: String? {
        parseInventoryQuantity(item.quantity)?.unit
    }

    init(item: InventoryItem, category: InventoryCategory, viewModel: InventoryViewModel) {
        self.item = item
        self.category = category
        self.viewModel = viewModel
        _editedName = State(initialValue: item.nameEnglish)
        _editedQuantity = State(initialValue: parseInventoryQuantity(item.quantity).map { inventoryFormatQuantity($0.value) } ?? item.quantity)
    }

    private var hasChanges: Bool {
        let nameChanged = editedName.trimmingCharacters(in: .whitespacesAndNewlines) != item.nameEnglish
        let originalQuantity = inventoryQuantityValue(item.quantity) ?? 0
        let editedQuantityValue = inventoryQuantityValue(editedQuantity)
        let quantityChanged: Bool
        if fixedUnit != nil {
            quantityChanged = editedQuantityValue.map { abs($0 - originalQuantity) > 0.0001 } ?? false
        } else {
            let editedPounds = editedQuantityValue.map { selectedUnit.pounds(from: $0) }
            quantityChanged = editedPounds.map { abs($0 - originalQuantity) > 0.0001 } ?? false
        }
        return nameChanged || quantityChanged
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        ItemImageView(item: item, height: 160, cornerRadius: 24)

                        VStack(spacing: 14) {
                            EditField(
                                label: "Item Name (English)",
                                placeholder: item.nameEnglish,
                                text: $editedName,
                                keyboardType: .default
                            )

                            EditField(
                                label: "Quantity",
                                placeholder: item.quantity,
                                text: $editedQuantity,
                                keyboardType: .decimalPad,
                                trailingContent: {
                                    if let fixedUnit {
                                        FixedUnitLabel(unit: fixedUnit)
                                    } else {
                                        UnitMenuPicker(selectedUnit: $selectedUnit)
                                    }
                                }
                            )
                        }
                        .onChange(of: selectedUnit) { oldUnit, newUnit in
                            if fixedUnit == nil {
                                convertEditedQuantity(from: oldUnit, to: newUnit)
                            }
                        }

                        if let saveError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(saveError)
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color(red: 0.55, green: 0.25, blue: 0.08))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                        }

                        Button(action: save) {
                            Group {
                                if isSaving {
                                    ProgressView().tint(.white)
                                } else {
                                    Text("Save Changes")
                                        .font(.system(size: 17, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(
                                        hasChanges && !isSaving
                                            ? Color(red: 0.60, green: 0.43, blue: 0.20)
                                            : Color.gray.opacity(0.4)
                                    )
                            )
                        }
                        .disabled(!hasChanges || isSaving)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color(red: 0.60, green: 0.43, blue: 0.20))
                        .disabled(isSaving)
                }
            }
        }
    }

    private func save() {
        Task {
            isSaving = true
            saveError = nil
            do {
                try await viewModel.updateItem(
                    in: category,
                    item: item,
                    newName: editedName.trimmingCharacters(in: .whitespacesAndNewlines),
                    enteredQuantity: editedQuantity.trimmingCharacters(in: .whitespacesAndNewlines),
                    enteredUnit: selectedUnit,
                    fixedUnit: fixedUnit
                )
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }

    private func convertEditedQuantity(from oldUnit: InventoryUnit, to newUnit: InventoryUnit) {
        guard oldUnit != newUnit else { return }

        let currentPounds = inventoryQuantityValue(editedQuantity)
            .map { oldUnit.pounds(from: $0) }
            ?? inventoryQuantityValue(item.quantity)
            ?? 0

        editedQuantity = inventoryFormatQuantity(newUnit.value(fromPounds: currentPounds))
    }
}

private struct FixedUnitLabel: View {
    let unit: String

    var body: some View {
        Text(unit)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.60, green: 0.43, blue: 0.20))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.97, green: 0.91, blue: 0.79))
            )
    }
}

// ── Edit field ───────────────────────────────────────────────────────────────

private struct EditField<TrailingContent: View>: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    @ViewBuilder let trailingContent: TrailingContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.55, green: 0.42, blue: 0.28))
                .padding(.horizontal, 4)

            HStack(spacing: 10) {
                TextField(placeholder, text: $text)
                    .keyboardType(keyboardType)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.15, blue: 0.13))
                    .tint(Color(red: 0.60, green: 0.43, blue: 0.20))

                trailingContent
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.95))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(red: 0.78, green: 0.60, blue: 0.38).opacity(0.5), lineWidth: 1.5)
            }
        }
    }
}

private extension EditField where TrailingContent == EmptyView {
    init(
        label: String,
        placeholder: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default
    ) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.keyboardType = keyboardType
        self.trailingContent = EmptyView()
    }
}

// ── Detail view ──────────────────────────────────────────────────────────────

private struct InventoryDetailView: View {
    let item: InventoryItem
    @ObservedObject var viewModel: InventoryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedUnit: InventoryUnit = .pounds

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                DetailGlassTopBar(
                    title: item.nameEnglish,
                    isRefreshDisabled: viewModel.isLoading,
                    onBack: { dismiss() },
                    onRefresh: {
                        Task { await viewModel.loadInventory(forceRefresh: true) }
                    }
                )

                ScrollView {
                    VStack(spacing: 24) {
                        ItemImageView(item: item, height: 240, cornerRadius: 28)

                        VStack(spacing: 18) {
                            DetailInfoBlock(
                                title: "English",
                                primaryText: item.nameEnglish,
                                secondaryText: item.typeEnglish
                            )

                            DetailInfoBlock(
                                title: "Gujarati",
                                primaryText: item.nameGujarati ?? item.nameEnglish,
                                secondaryText: item.typeGujarati ?? item.typeEnglish
                            )

                            QuantityUnitBlock(
                                quantity: item.quantity,
                                selectedUnit: $selectedUnit
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
            }
        }
        .navigationTitle(item.nameEnglish)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct QuantityUnitBlock: View {
    let quantity: String
    @Binding var selectedUnit: InventoryUnit

    private var quantityParts: InventoryQuantityParts? {
        parseInventoryQuantity(quantity)
    }

    private var convertedQuantity: String {
        guard let quantityParts else {
            return quantity
        }
        if quantityParts.hasFixedUnit {
            return inventoryFormatQuantity(quantityParts.value)
        }
        let pounds = quantityParts.value
        let converted = selectedUnit.value(fromPounds: pounds)
        return inventoryFormatQuantity(converted)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Quantity")
                .font(.headline)
                .foregroundStyle(Color(red: 0.45, green: 0.37, blue: 0.30))

            HStack(alignment: .center, spacing: 14) {
                Text(convertedQuantity)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.24, green: 0.17, blue: 0.08))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let fixedUnit = quantityParts?.unit {
                    FixedUnitLabel(unit: fixedUnit)
                } else {
                    UnitMenuPicker(selectedUnit: $selectedUnit, style: .large)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Text("સ્ટોક")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.45, green: 0.37, blue: 0.30))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .background(
            Color.white.opacity(0.96),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

private struct UnitMenuPicker: View {
    @Binding var selectedUnit: InventoryUnit
    var style: UnitMenuPickerStyle = .compact

    var body: some View {
        Menu {
            Picker("Unit", selection: $selectedUnit) {
                ForEach(InventoryUnit.allCases) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
        } label: {
            HStack(spacing: style.spacing) {
                Text(selectedUnit.displayName)
                    .font(.system(size: style.textSize, weight: .bold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: style.iconSize, weight: .bold))
            }
            .foregroundStyle(Color(red: 0.60, green: 0.43, blue: 0.20))
            .padding(.horizontal, style.horizontalPadding)
            .padding(.vertical, style.verticalPadding)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.97, green: 0.91, blue: 0.79))
            )
        }
    }
}

private enum UnitMenuPickerStyle {
    case compact
    case large

    var textSize: CGFloat {
        switch self {
        case .compact: 15
        case .large: 20
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .compact: 11
        case .large: 13
        }
    }

    var spacing: CGFloat {
        switch self {
        case .compact: 5
        case .large: 7
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: 11
        case .large: 16
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: 7
        case .large: 10
        }
    }
}

// ── Detail info block ────────────────────────────────────────────────────────

private struct DetailInfoBlock: View {
    let title: String
    let primaryText: String
    let secondaryText: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color(red: 0.67, green: 0.48, blue: 0.29))

            Text(primaryText)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.18, green: 0.15, blue: 0.13))
                .multilineTextAlignment(.center)

            Text(secondaryText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(red: 0.45, green: 0.37, blue: 0.30))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .background(
            Color.white.opacity(0.96),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

// ── Depth card ───────────────────────────────────────────────────────────────

private struct DepthCardContainer<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    init(height: CGFloat, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let cardFrame = geometry.frame(in: .global)
            let rotation = cardRotation(for: cardFrame)

            content
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color(red: 0.80, green: 0.73, blue: 0.61).opacity(0.26))
                            .offset(x: 0, y: 10)

                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white.opacity(0.96))

                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.65), Color.white.opacity(0.04)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
                .rotation3DEffect(rotation, axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        }
        .frame(height: height)
    }

    private func cardRotation(for frame: CGRect) -> Angle {
        let screenHeight = UIScreen.main.bounds.height
        let centerY = frame.midY
        let normalizedOffset = (centerY / screenHeight) - 0.5
        let horizontalOffset = (frame.midX / UIScreen.main.bounds.width) - 0.5
        let verticalOffset = normalizedOffset

        return .degrees(
            Double(-verticalOffset * 7) + Double(horizontalOffset * 9)
        )
    }
}

// ── Category preview ─────────────────────────────────────────────────────────

private struct CategoryPreviewView: View {
    let category: InventoryCategory

    private var previewItems: [InventoryItem] { Array(category.items.prefix(4)) }

    private var palette: [Color] {
        let sets: [[Color]] = [
            [Color(red: 0.87, green: 0.67, blue: 0.29), Color(red: 0.69, green: 0.47, blue: 0.14)],
            [Color(red: 0.35, green: 0.67, blue: 0.45), Color(red: 0.22, green: 0.48, blue: 0.30)],
            [Color(red: 0.81, green: 0.55, blue: 0.31), Color(red: 0.68, green: 0.39, blue: 0.20)],
            [Color(red: 0.74, green: 0.56, blue: 0.27), Color(red: 0.54, green: 0.39, blue: 0.13)]
        ]
        return sets[abs(category.nameEnglish.hashValue) % sets.count]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))

            if let imageURL = category.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty: ProgressView().tint(.white)
                    case .success(let image): image.resizable().scaledToFill()
                    default: previewFallback
                    }
                }
            } else {
                previewFallback
            }
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var previewFallback: some View {
        if previewItems.isEmpty {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        } else {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(previewItems) { item in
                    ZStack {
                        Circle().fill(.white.opacity(0.18))
                        FoodIllustration(itemName: item.nameEnglish).padding(10)
                    }
                    .frame(width: 48, height: 48)
                }
            }
            .padding(18)
        }
    }
}

// ── Item image view ──────────────────────────────────────────────────────────

private struct ItemImageView: View {
    let item: InventoryItem
    var height: CGFloat = 116
    var cornerRadius: CGFloat = 18

    private var palette: [Color] {
        let sets: [[Color]] = [
            [Color(red: 0.91, green: 0.63, blue: 0.35), Color(red: 0.69, green: 0.35, blue: 0.14)],
            [Color(red: 0.39, green: 0.74, blue: 0.53), Color(red: 0.18, green: 0.49, blue: 0.27)],
            [Color(red: 0.92, green: 0.52, blue: 0.48), Color(red: 0.69, green: 0.18, blue: 0.23)],
            [Color(red: 0.95, green: 0.77, blue: 0.39), Color(red: 0.79, green: 0.56, blue: 0.14)]
        ]
        return sets[abs(item.nameEnglish.hashValue) % sets.count]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))

            if let imageURL = item.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty: ProgressView().tint(.white)
                    case .success(let image): image.resizable().scaledToFill()
                    default: FoodIllustration(itemName: item.nameEnglish).padding(18)
                    }
                }
            } else {
                FoodIllustration(itemName: item.nameEnglish).padding(18)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// ── Food illustrations (unchanged) ───────────────────────────────────────────

private struct FoodIllustration: View {
    let itemName: String
    private var key: String { itemName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle().fill(.white.opacity(0.16)).frame(width: size * 0.72, height: size * 0.72)
                switch key {
                case "wheat":    WheatArt()
                case "turmeric": TurmericArt()
                case "millet", "bajri": MilletArt()
                case "clove":    CloveArt()
                case "ragi":     RagiArt()
                case "mag":      MagArt()
                default:         GenericProduceArt()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WheatArt: View {
    var body: some View {
        ZStack {
            Capsule().fill(Color.white.opacity(0.9)).frame(width: 6, height: 64).offset(y: 10)
            ForEach(0..<5, id: \.self) { index in
                HStack(spacing: 18) {
                    Ellipse().fill(Color.white.opacity(0.95)).frame(width: 18, height: 10).rotationEffect(.degrees(-28))
                    Ellipse().fill(Color.white.opacity(0.95)).frame(width: 18, height: 10).rotationEffect(.degrees(28))
                }
                .offset(y: CGFloat(index * 10) - 16)
            }
        }
    }
}

private struct TurmericArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.96)).frame(width: 58, height: 26).rotationEffect(.degrees(-18))
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.88)).frame(width: 52, height: 24).rotationEffect(.degrees(20)).offset(x: 18, y: 12)
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.78)).frame(width: 42, height: 20).rotationEffect(.degrees(-42)).offset(x: -20, y: 16)
            Capsule().fill(Color(red: 1.0, green: 0.78, blue: 0.34)).frame(width: 34, height: 8).rotationEffect(.degrees(20)).offset(x: 18, y: 12)
        }
    }
}

private struct MilletArt: View {
    var body: some View {
        ZStack {
            Capsule().fill(Color.white.opacity(0.88)).frame(width: 6, height: 62).offset(y: 10)
            VStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: 5) {
                        ForEach(0..<4, id: \.self) { _ in
                            Circle().fill(Color.white.opacity(0.95)).frame(width: 9, height: 9)
                        }
                    }
                }
            }
            .offset(y: -12)
        }
    }
}

private struct CloveArt: View {
    var body: some View {
        HStack(spacing: 12) {
            CloveStem().rotationEffect(.degrees(-18))
            CloveStem().rotationEffect(.degrees(16))
        }
    }
}

private struct CloveStem: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.96))
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 0.83, green: 0.43, blue: 0.38))
                }
            Capsule().fill(Color.white.opacity(0.86)).frame(width: 8, height: 34)
        }
    }
}

private struct RagiArt: View {
    var body: some View {
        ZStack {
            Capsule().fill(Color.white.opacity(0.88)).frame(width: 6, height: 58).offset(y: 14)
            ForEach(0..<6, id: \.self) { index in
                Circle().fill(Color.white.opacity(0.94)).frame(width: 11, height: 11)
                    .offset(x: index.isMultiple(of: 2) ? -CGFloat(index * 5) : CGFloat(index * 5), y: -CGFloat(index * 5))
            }
        }
    }
}

private struct MagArt: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 18, height: 26)
                    .overlay { Capsule().fill(Color(red: 0.58, green: 0.83, blue: 0.55)).frame(width: 10, height: 4) }
                    .rotationEffect(.degrees(index == 1 ? 0 : (index == 0 ? -18 : 18)))
            }
        }
    }
}

private struct GenericProduceArt: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "leaf.fill").font(.system(size: 28, weight: .bold)).foregroundStyle(.white.opacity(0.95))
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.88)).frame(width: 36, height: 24)
        }
    }
}

// ── Shared helpers ───────────────────────────────────────────────────────────

private var backgroundGradient: LinearGradient {
    LinearGradient(
        colors: [
            Color(red: 0.97, green: 0.91, blue: 0.79),
            Color(red: 0.91, green: 0.96, blue: 0.88)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private func inventoryQuantityValue(_ value: String) -> Double? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }

    let allowedCharacters = CharacterSet(charactersIn: "0123456789.-")
    let numericString = String(normalized.unicodeScalars.filter { allowedCharacters.contains($0) })
    guard !numericString.isEmpty else { return nil }
    return Double(numericString)
}

private func inventoryFormatQuantity(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
}

private func inventoryQuantityWithPoundsUnit(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "0 lbs" }

    if trimmed.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil {
        return trimmed
    }
    return "\(trimmed) lbs"
}

private extension View {
    func highlightedBorder(_ isHighlighted: Bool) -> some View {
        overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(red: 0.78, green: 0.53, blue: 0.16), lineWidth: 3)
                    .padding(2)
            }
        }
    }
}

#Preview {
    ContentView(isEditMode: false, viewModel: InventoryViewModel())
}
