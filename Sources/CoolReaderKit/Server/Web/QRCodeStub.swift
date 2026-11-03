// Temporary: replaced by the QR code encoder's branch.
nonisolated struct QRCode {
    init(_ text: String) throws {}
    func svg(moduleSize: Int, title: String?) -> String { "<svg></svg>" }
}
