import Fluent
import FluentSQL
import Ink
import OrchardNestKit
import Plot
import QueuesFluentDriver
import Vapor

struct HTMLController {
  let views: [String: Markdown]
  static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .medium
    return formatter
  }()

  init(markdownDirectory: String) {
    let parser = MarkdownParser()

    let textPairs = FileManager.default.enumerator(atPath: markdownDirectory)?.compactMap { $0 as? String }.map { path in
      URL(fileURLWithPath: markdownDirectory + path)
    }.compactMap { url in
      (try? String(contentsOf: url)).map { (url.deletingPathExtension().lastPathComponent, $0) }
    }

    views = textPairs.map(Dictionary.init(uniqueKeysWithValues:))?.mapValues(
      parser.parse
    ) ?? [String: Markdown]()
  }

  func category(req: Request) throws -> EventLoopFuture<HTML> {
    guard let category = req.parameters.get("category") else {
      throw Abort(.notFound)
    }

    return EntryController.entries(from: req.db)
      .filter(Channel.self, \Channel.$category.$id == category)
      .filter(Channel.self, \Channel.$language.$id == "en")
      .limit(32)
      .all()
      .flatMapThrowing { (entries) -> [Entry] in
        guard entries.count > 0 else {
          throw Abort(.notFound)
        }
        return entries
      }
      .flatMapEachThrowing {
        try EntryItem(entry: $0)
      }
      .map { (items) -> HTML in
        HTML(
          .head(withSubtitle: "Swift Articles and News", andDescription: "Swift Articles and News of Category \(category)"),
          .body(
            .class("category \(category)"),
            .header(),
            .main(
              .class("container"),
              .filters(),
              .section(
                .class("row"),
                .ul(
                  .class("articles column"),
                  .forEach(items) {
                    .li(forEntryItem: $0, formatDateWith: Self.dateFormatter)
                  }
                )
              )
            )
          )
        )
      }
  }

  func page(req: Request) -> EventLoopFuture<HTML> {
    guard let name = req.parameters.get("page") else {
      return req.eventLoop.makeFailedFuture(Abort(.notFound))
    }

    guard let view = views[name] else {
      return req.eventLoop.makeFailedFuture(Abort(.notFound))
    }

    let html = HTML(
      .head(withSubtitle: "Support and FAQ", andDescription: view.metadata["description"] ?? name),
      .body(
        .header(),
        .main(
          .class("container"),
          .filters(),
          .section(
            .class("row"),
            .raw(view.html)
          )
        )
      )
    )

    return req.eventLoop.future(html)
  }

  func channel(req: Request) throws -> EventLoopFuture<HTML> {
    guard let channel = req.parameters.get("channel").flatMap({ $0.base32UUID }) else {
      throw Abort(.notFound)
    }

    return EntryController.entries(from: req.db)
      .filter(Channel.self, \Channel.$id == channel)
      .limit(32)
      .all()
      .flatMapEachThrowing {
        try EntryItem(entry: $0)
      }
      .map { (items) -> HTML in
        HTML(
          .head(withSubtitle: "Swift Articles and News", andDescription: "Swift Articles and News"),
          .body(
            .header(),
            .main(
              .class("container"),
              .filters(),
              .section(
                .class("row"),
                .ul(
                  .class("articles column"),
                  .forEach(items) {
                    .li(forEntryItem: $0, formatDateWith: Self.dateFormatter)
                  }
                )
              )
            )
          )
        )
      }
  }

  func index(req: Request) -> EventLoopFuture<HTML> {
    return EntryController.entries(from: req.db)
      .join(LatestEntry.self, on: \Entry.$id == \LatestEntry.$id)
      .filter(Channel.self, \Channel.$category.$id != "updates")
      .filter(Channel.self, \Channel.$language.$id == "en")
      .limit(32)
      .all()
      .flatMapEachThrowing {
        try EntryItem(entry: $0)
      }
      .map { (items) -> HTML in
        HTML(
          .head(withSubtitle: "Swift Articles and News", andDescription: "Swift Articles and News"),
          .body(
            .header(),
            .main(
              .class("container"),
              .filters(),
              .section(
                .class("row"),
                .ul(
                  .class("articles column"),
                  .forEach(items) {
                    .li(forEntryItem: $0, formatDateWith: Self.dateFormatter)
                  }
                )
              )
            )
          )
        )
      }
  }

  func sitemap(req: Request) -> EventLoopFuture<SiteMap> {
    let last = (req.queue as? FluentQueue).map {
      $0.list(state: .completed).map { $0.map { $0.queuedAt }.max() }
    } ?? req.eventLoop.makeSucceededFuture(nil)
    let urls = req.application.routes.all.filter { route in

      guard route.method == .GET else {
        return false
      }

      if case let .constant(name) = route.path.first {
        guard name != "api" else {
          return false
        }
      }

      if case let .constant(name) = route.path.last {
        guard name != "sitemap.xml" else {
          return false
        }
      }

      return true
    }.map { (route) -> EventLoopFuture<[URL]> in
      let baseURL = URL(string: "https://orchardnest.com")!

      let components: [SiteMapPathComponent] = route.path.compactMap { path in
        switch path {
        case let .constant(constant):
          return .name(constant)
        case let .parameter(parameter):
          guard let mappable = MappableParameter(rawValue: parameter) else {
            return nil
          }
          return .parameter(mappable)
        default:
          return nil
        }
      }

      let urls = components.map { (component) -> EventLoopFuture<[String]> in
        switch component {
        case let .name(name):
          return req.eventLoop.makeSucceededFuture([name])
        case let .parameter(parameter):
          return parameter.pathComponents(on: req.db, withViews: [String](self.views.keys), from: req.eventLoop)
        }
      }.flatten(on: req.eventLoop).map { $0.crossReduce().map { $0.joined(separator: "/") }.map(baseURL.safeAppendingPathComponent(_:)) }

      return urls
    }.flatten(on: req.eventLoop)

    return urls.map { $0.flatMap { $0 }}.and(last).map { (urls, last) -> SiteMap in
      SiteMap(
        .forEach(urls) { url in
          .url(
            .loc(url),
            .changefreq(.hourly),
            .unwrap(last) {
              .lastmod($0)
            }
          )
        }
      )
    }
  }
}

extension HTMLController: RouteCollection {
  func boot(routes: RoutesBuilder) throws {
    routes.get("", use: index)
    routes.get("categories", ":category", use: category)
    routes.get(":page", use: page)
    routes.get("channels", ":channel", use: channel)
    routes.get("sitemap.xml", use: sitemap)
  }
}
