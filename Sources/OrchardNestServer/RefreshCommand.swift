import Vapor

struct RefreshCommand: Command {
  typealias Signature = RefreshConfiguration

  var help: String

  func run(using context: CommandContext, signature _: RefreshConfiguration) throws {
    let process = RefreshProcess()
    let parameters = RefreshParameters(logger: context.application.logger, database: context.application.db, client: context.application.client)
    try process.begin(using: parameters, on: context.application.db.eventLoop).wait()
  }
}
