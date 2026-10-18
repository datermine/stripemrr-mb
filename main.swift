// Shows Stripe MRR in the macOS menu bar, refreshing every 3 hours.
//
// MRR is computed the way Stripe's Billing overview describes it: active and
// past_due subscriptions, each price normalized to a month, discounts applied,
// tax excluded, trials excluded. Metered (usage-based) items are not counted.
//
// API key: a restricted key with read access to Subscriptions, stored in the
// Keychain (or set STRIPE_API_KEY to override):
//   security add-generic-password -s stripe-mrr -a "$USER" -w
//
// Run with --print to compute once and print a per-subscription breakdown.

import AppKit

let keychainService = "stripe-mrr"
let stripeAPIVersion = "2024-06-20"
let refreshInterval: TimeInterval = 3 * 60 * 60
let retryInterval: TimeInterval = 5 * 60
let dashboardURL = URL(string: "https://dashboard.stripe.com/billing/revenue")!
let menuBarTextKey = "menuBarText"
let zeroDecimalCurrencies: Set<String> = [
    "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga",
    "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf",
]

// MARK: - Stripe models (shapes as of stripeAPIVersion)

protocol StripeObject: Decodable {
    var id: String { get }
}

struct StripeList<T: Decodable>: Decodable {
    let data: [T]
    let hasMore: Bool
}

struct Subscription: StripeObject {
    let id: String
    let status: String
    let currency: String
    let items: StripeList<SubscriptionItem>
    let discount: Discount?
    let discounts: [Discount]?
}

struct SubscriptionItem: StripeObject {
    let id: String
    let price: Price
    let quantity: Int?
    let discounts: [Discount]?
}

struct Price: Decodable {
    let id: String
    let unitAmountDecimal: String?
    let billingScheme: String
    let tiersMode: String?
    let tiers: [Tier]?
    let transformQuantity: TransformQuantity?
    let recurring: Recurring?
}

struct Tier: Decodable {
    let upTo: Int?
    let unitAmountDecimal: String?
    let flatAmountDecimal: String?
}

struct TransformQuantity: Decodable {
    let divideBy: Int
    let round: String
}

struct Recurring: Decodable {
    let interval: String
    let intervalCount: Int
    let usageType: String
}

struct Discount: Decodable {
    let coupon: Coupon
    let end: Int?
}

struct Coupon: Decodable {
    let percentOff: Double?
    let amountOff: Int?
}

struct StripeErrorBody: Decodable {
    struct Detail: Decodable { let message: String? }
    let error: Detail
}

enum MRRError: LocalizedError {
    case missingKey
    case stripe(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "No Stripe key in Keychain (service \"\(keychainService)\")"
        case .stripe(let status, let message): "Stripe \(status): \(message)"
        }
    }
}

// MARK: - Stripe client

let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}()

func loadAPIKey() throws -> String {
    if let key = ProcessInfo.processInfo.environment["STRIPE_API_KEY"], !key.isEmpty {
        return key
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, !key.isEmpty else { throw MRRError.missingKey }
    return key
}

struct StripeClient {
    let apiKey: String

    func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(string: "https://api.stripe.com/v1/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(stripeAPIVersion, forHTTPHeaderField: "Stripe-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? decoder.decode(StripeErrorBody.self, from: data))?.error.message
            throw MRRError.stripe(status: status, message: message ?? "unexpected response")
        }
        return try decoder.decode(T.self, from: data)
    }

    func listAll<T: StripeObject>(_ path: String, _ query: [URLQueryItem]) async throws -> [T] {
        var all: [T] = []
        var startingAfter: String?
        repeat {
            var pageQuery = query + [URLQueryItem(name: "limit", value: "100")]
            if let startingAfter { pageQuery.append(URLQueryItem(name: "starting_after", value: startingAfter)) }
            let page: StripeList<T> = try await get(path, pageQuery)
            all += page.data
            startingAfter = page.hasMore ? page.data.last?.id : nil
        } while startingAfter != nil
        return all
    }
}

// MARK: - MRR

struct SubscriptionMRR {
    let id: String
    let status: String
    let currency: String
    let monthly: Double  // major units
}

struct MRRResult {
    let subscriptions: [SubscriptionMRR]
    let meteredItems: Int
    let fetchedAt: Date

    /// MRR per currency, largest first.
    var totals: [(currency: String, amount: Double)] {
        Dictionary(grouping: subscriptions, by: \.currency)
            .map { (currency: $0.key, amount: $0.value.reduce(0) { $0 + $1.monthly }) }
            .sorted { $0.amount > $1.amount }
    }
}

func decimal(_ string: String?) -> Double {
    string.flatMap(Double.init) ?? 0
}

func monthlyFactor(_ recurring: Recurring) -> Double {
    let count = Double(recurring.intervalCount)
    switch recurring.interval {
    case "day": return 365.0 / 12.0 / count
    case "week": return 52.0 / 12.0 / count
    case "year": return 1.0 / (12.0 * count)
    default: return 1.0 / count
    }
}

func tieredAmount(_ tiers: [Tier], mode: String, quantity: Int) -> Double {
    if mode == "volume" {
        guard let tier = tiers.first(where: { $0.upTo.map { quantity <= $0 } ?? true }) else { return 0 }
        return decimal(tier.unitAmountDecimal) * Double(quantity) + decimal(tier.flatAmountDecimal)
    }
    var total = 0.0
    var previousCap = 0
    for tier in tiers where quantity > previousCap {
        let cap = min(quantity, tier.upTo ?? quantity)
        total += decimal(tier.unitAmountDecimal) * Double(cap - previousCap) + decimal(tier.flatAmountDecimal)
        previousCap = cap
    }
    return total
}

/// Amount billed per interval for one item, in minor units, before discounts.
func periodAmount(_ price: Price, quantity: Int) -> Double {
    if price.billingScheme == "tiered", let tiers = price.tiers {
        return tieredAmount(tiers, mode: price.tiersMode ?? "volume", quantity: quantity)
    }
    var units = Double(quantity)
    if let transform = price.transformQuantity {
        units = (units / Double(transform.divideBy)).rounded(transform.round == "up" ? .up : .down)
    }
    return decimal(price.unitAmountDecimal) * units
}

/// Applies unexpired discounts in order. `amountOffScale` converts a per-period
/// amount_off into the same units as `amount`.
func applying(_ discounts: [Discount], to amount: Double, amountOffScale: Double = 1, now: Date) -> Double {
    discounts
        .filter { $0.end.map { Date(timeIntervalSince1970: TimeInterval($0)) > now } ?? true }
        .reduce(amount) { total, discount in
            if let percentOff = discount.coupon.percentOff { return total * (1 - percentOff / 100) }
            if let amountOff = discount.coupon.amountOff { return max(0, total - Double(amountOff) * amountOffScale) }
            return total
        }
}

func fetchMRR() async throws -> MRRResult {
    let client = StripeClient(apiKey: try loadAPIKey())
    let now = Date()

    var subscriptions: [Subscription] = []
    for status in ["active", "past_due"] {
        subscriptions += try await client.listAll("subscriptions", [
            URLQueryItem(name: "status", value: status),
            URLQueryItem(name: "expand[]", value: "data.discounts"),
            URLQueryItem(name: "expand[]", value: "data.items.data.discounts"),
        ])
    }

    var tieredPrices: [String: Price] = [:]
    var meteredItems = 0
    var results: [SubscriptionMRR] = []

    for subscription in subscriptions {
        var items = subscription.items.data
        if subscription.items.hasMore {
            items = try await client.listAll("subscription_items", [
                URLQueryItem(name: "subscription", value: subscription.id),
                URLQueryItem(name: "expand[]", value: "data.discounts"),
            ])
        }

        var monthly = 0.0
        var factor = 1.0
        for item in items {
            var price = item.price
            guard let recurring = price.recurring else { continue }
            if recurring.usageType == "metered" {
                meteredItems += 1
                continue
            }
            if price.billingScheme == "tiered" && price.tiers == nil {
                if tieredPrices[price.id] == nil {
                    tieredPrices[price.id] = try await client.get("prices/\(price.id)", [URLQueryItem(name: "expand[]", value: "tiers")])
                }
                price = tieredPrices[price.id]!
            }
            factor = monthlyFactor(recurring)
            let perPeriod = applying(item.discounts ?? [], to: periodAmount(price, quantity: item.quantity ?? 1), now: now)
            monthly += perPeriod * factor
        }

        // `discounts` supersedes the legacy single `discount`; only fall back to it.
        let subscriptionDiscounts = subscription.discounts.flatMap { $0.isEmpty ? nil : $0 }
            ?? subscription.discount.map { [$0] } ?? []
        monthly = applying(subscriptionDiscounts, to: monthly, amountOffScale: factor, now: now)

        let currency = subscription.currency
        let major = zeroDecimalCurrencies.contains(currency) ? monthly : monthly / 100
        results.append(SubscriptionMRR(id: subscription.id, status: subscription.status, currency: currency, monthly: major))
    }

    return MRRResult(subscriptions: results, meteredItems: meteredItems, fetchedAt: now)
}

func formatMoney(_ amount: Double, _ currency: String, fractionDigits: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency.uppercased()
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    return formatter.string(from: amount as NSNumber) ?? "\(amount)"
}

// MARK: - Menu bar

@MainActor
final class MenuBarController: NSObject {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var result: MRRResult?
    var lastError: Error?
    var lastAttempt: Date?
    var loading = false

    override init() {
        super.init()
        render()
        Timer.scheduledTimer(timeInterval: retryInterval, target: self, selector: #selector(refreshIfDue), userInfo: nil, repeats: true)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshIfDue), name: NSWorkspace.didWakeNotification, object: nil)
        refreshIfDue()
    }

    /// Ticks every few minutes so refreshes survive sleep and failed attempts retry.
    @objc func refreshIfDue() {
        let now = Date()
        let stale = result.map { now.timeIntervalSince($0.fetchedAt) >= refreshInterval } ?? true
        let backingOff = lastAttempt.map { now.timeIntervalSince($0) < retryInterval } ?? false
        if stale && !backingOff { refresh() }
    }

    @objc func refresh() {
        guard !loading else { return }
        loading = true
        lastAttempt = Date()
        render()
        Task {
            do {
                result = try await fetchMRR()
                lastError = nil
            } catch {
                lastError = error
            }
            loading = false
            render()
        }
    }

    @objc func openDashboard() {
        NSWorkspace.shared.open(dashboardURL)
    }

    /// Custom text shown in the menu bar instead of MRR; empty means show MRR.
    var menuBarText: String {
        UserDefaults.standard.string(forKey: menuBarTextKey) ?? ""
    }

    @objc func editMenuBarText() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = menuBarText
        field.placeholderString = "e.g. 💰"
        let alert = NSAlert()
        alert.messageText = "Menu Bar Text"
        alert.informativeText = "Shown in the menu bar instead of your MRR. Leave empty to show MRR."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setMenuBarText(field.stringValue)
    }

    @objc func clearMenuBarText() {
        setMenuBarText("")
    }

    private func setMenuBarText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: menuBarTextKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: menuBarTextKey)
        }
        render()
    }

    func render() {
        var title = menuBarText
        if title.isEmpty {
            title = result?.totals.first.map { formatMoney($0.amount, $0.currency, fractionDigits: 0) } ?? "MRR"
            if loading && result == nil { title += " …" }
        }
        if lastError != nil { title += " ⚠︎" }
        statusItem.button?.title = title

        let menu = NSMenu()
        menu.autoenablesItems = false
        if let result {
            for total in result.totals {
                menu.addItem(info("MRR  \(formatMoney(total.amount, total.currency, fractionDigits: 2))"))
                menu.addItem(info("ARR  \(formatMoney(total.amount * 12, total.currency, fractionDigits: 2))"))
            }
            menu.addItem(info("\(result.subscriptions.count) active subscriptions"))
            if result.meteredItems > 0 {
                menu.addItem(info("\(result.meteredItems) metered items not counted"))
            }
            menu.addItem(info("Updated \(result.fetchedAt.formatted(date: .omitted, time: .shortened))"))
        }
        if let lastError {
            let item = info("⚠︎ \(lastError.localizedDescription.prefix(100))")
            item.toolTip = lastError.localizedDescription
            menu.addItem(item)
        }
        if loading { menu.addItem(info("Refreshing…")) }
        menu.addItem(.separator())
        menu.addItem(action("Refresh Now", #selector(refresh), key: "r"))
        menu.addItem(action("Open Billing Overview", #selector(openDashboard), key: "o"))
        menu.addItem(.separator())
        menu.addItem(action("Set Menu Bar Text…", #selector(editMenuBarText), key: ""))
        if !menuBarText.isEmpty {
            menu.addItem(action("Clear Menu Bar Text", #selector(clearMenuBarText), key: ""))
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func info(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }
}

// MARK: - Main

/// Menu-bar-only apps have no Edit menu, so ⌘X/⌘C/⌘V/⌘A don't reach text
/// fields without one. It's never shown; it only routes the key equivalents.
@MainActor
func makeEditMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem()
    editItem.submenu = edit
    let main = NSMenu()
    main.addItem(NSMenuItem())  // app menu slot
    main.addItem(editItem)
    return main
}

func printReport(_ result: MRRResult) {
    for sub in result.subscriptions.sorted(by: { $0.monthly > $1.monthly }) {
        let id = sub.id.padding(toLength: 32, withPad: " ", startingAt: 0)
        let status = sub.status.padding(toLength: 10, withPad: " ", startingAt: 0)
        print(id, status, formatMoney(sub.monthly, sub.currency, fractionDigits: 2))
    }
    print()
    for total in result.totals {
        print("MRR", formatMoney(total.amount, total.currency, fractionDigits: 2))
        print("ARR", formatMoney(total.amount * 12, total.currency, fractionDigits: 2))
    }
    print("\(result.subscriptions.count) subscriptions, \(result.meteredItems) metered items not counted")
}

if CommandLine.arguments.contains("--print") {
    Task {
        do {
            printReport(try await fetchMRR())
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.mainMenu = makeEditMenu()
    let controller = MenuBarController()
    withExtendedLifetime(controller) { app.run() }
}
