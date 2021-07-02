import Vapor

struct RefreshCommand: Command {
  typealias Signature = DirectoryConfiguration

  var help: String

  func run(using context: CommandContext, signature _: DirectoryConfiguration) throws {
    let process = RefreshProcess()
    let parameters = RefreshParameters(logger: context.application.logger, database: context.application.db, client: context.application.client)
    return try process.importFeeds(withParameters: parameters, on: context.application.db.eventLoop).wait()
  }
}
