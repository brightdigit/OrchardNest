import Fluent
import Vapor

struct EntryController {
  func list(req: Request) -> EventLoopFuture<Page<Entry>> {
    return Entry.query(on: req.db).sort(\.$publishedAt, .descending).with(\.$channel).paginate(for: req)
  }
}

extension EntryController: RouteCollection {
  func boot(routes: RoutesBuilder) throws {
    routes.get("", use: list)
  }
}
