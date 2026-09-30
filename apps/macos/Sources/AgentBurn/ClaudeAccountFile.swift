import Foundation

/// The newest Claude account meters, kept apart from the report cache so a
/// restart, a source change or an expired Claude Code sign-in never blanks them.
struct ClaudeAccountFile {
  let directory: URL
  var url: URL { directory.appendingPathComponent("claude-account.json") }
  private var backup: URL { url.appendingPathExtension("bak") }

  func load() -> ClaudeAccount? {
    [url, backup].lazy.compactMap(decode).first
  }

  func save(_ account: ClaudeAccount) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // Never replace the recovery copy with a corrupt primary file.
    if let previous = try? Data(contentsOf: url), decode(url) != nil {
      try previous.write(to: backup, options: .atomic)
    }
    try JSONEncoder().encode(account).write(to: url, options: .atomic)
  }

  private func decode(_ file: URL) -> ClaudeAccount? {
    try? JSONDecoder().decode(ClaudeAccount.self, from: Data(contentsOf: file))
  }
}

/// The account Anthropic reported most recently; ties keep the earlier candidate.
func latestClaudeAccount(_ accounts: [ClaudeAccount]) -> ClaudeAccount? {
  accounts.reduce(nil) { best, next in
    guard let best else { return next }
    return (next.observedAtMs ?? 0) > (best.observedAtMs ?? 0) ? next : best
  }
}
