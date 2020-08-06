import Fluent
import FluentSQL
import OrchardNestKit
import Plot
import Vapor

struct InvalidDatabaseError: Error {}

extension Node where Context == HTML.BodyContext {
  static func filters() -> Self {
    .nav(
      .class("posts-filter clearfix row"),
      .ul(
        .class("column"),
        .li(.a(.class("button"), .href("/"), .i(.class("el el-calendar")), .text(" Latest"))),
        .li(.a(.class("button"), .href("/category/development"), .i(.class("el el-cogs")), .text(" Development"))),
        .li(.a(.class("button"), .href("/category/marketing"), .i(.class("el el-bullhorn")), .text(" Marketing"))),
        .li(.a(.class("button"), .href("/category/design"), .i(.class("el el-brush")), .text(" Design"))),
        .li(.a(.class("button"), .href("/category/podcasts"), .i(.class("el el-podcast")), .text(" Podcasts"))),
        .li(.a(.class("button"), .href("/category/youtube"), .i(.class("el el-video")), .text(" YouTube"))),
        .li(.a(.class("button"), .href("/category/newsletters"), .i(.class("el el-envelope")), .text(" Newsletters")))
      )
    )
  }
}

extension Node where Context == HTML.BodyContext {
  static func header() -> Self {
    .header(
      .class("container"),
      .nav(
        .class("row"),
        .ul(
          .class("column"),
          .li(.a(.href("/"), .i(.class("el el-home")), .text(" Home"))),
          .li(.a(.href("/about"), .i(.class("el el-info-circle")), .text(" About"))),
          .li(.a(.href("/support"), .i(.class("el el-question-sign")), .text(" Support")))
        ),
        .ul(.class("float-right column"),
            .li(.a(.href("https://github.com/brightdigit/OrchardNest"), .i(.class("el el-github")), .text(" github"))),
            .li(.a(.href("https://twitter.com/OrchardNest"), .i(.class("el el-twitter")), .text(" twitter"))))
      ),
      .div(
        .class("row"),
        .h1(
          .class("column"),
          .img(
            .class("logo"),
            .src("/images/logo.svg")
          ),
          .text("&nbsp;OrchardNest")
        )
      ),
      div(
        .class("row"),
        .p(
          .class("tagline column"),
          .text("Swift Articles and News")
        )
      )
    )
  }
}

extension Node where Context == HTML.DocumentContext {
  static func head(withSubtitle subtitle: String) -> Self {
    return
      .head(
        .title("OrchardNest - \(subtitle)"),
        .meta(.charset(.utf8)),

        .link(.rel(.appleTouchIcon), .sizes("180x180"), .href("/apple-touch-icon.png")),
        .link(.rel(.appleTouchIcon), .type("image/png"), .sizes("32x32"), .href("/favicon-32x32.png")),
        .link(.rel(.appleTouchIcon), .type("image/png"), .sizes("16x16"), .href("/favicon-16x16.png")),
        .link(.rel(.manifest), .href("/site.webmanifest")),
        .link(.rel(.maskIcon), .href("/safari-pinned-tab.svg"), .color("#5bbad5")),
        .meta(.name("msapplication-TileColor"), .content("#2b5797")),
        .meta(.name("theme-color"), .content("#ffffff")),
        .link(.rel(.stylesheet), .href("/styles/elusive-icons/css/elusive-icons.min.css")),

        .link(.rel(.stylesheet), .href("/styles/normalize.css")),

        .link(.rel(.stylesheet), .href("/styles/milligram.css")),
        .link(.rel(.stylesheet), .href("/styles/style.css")),
        .link(.rel(.stylesheet), .href("https://fonts.googleapis.com/css2?family=Catamaran:wght@100;400;800&display=swap"))
      )
  }
}

extension Node where Context == HTML.ListContext {
  static func li(forEntryItem item: EntryItem) -> Self {
    return
      .li(
        .class("blog-post"),

        .a(
          .href(item.url),
          .class("title"),
          .h3(
            .i(.class("el el-\(item.category.elClass)")),

            .text(item.title)
          )
        ),
        .div(
          .class("publishedAt"),
          .text(item.publishedAt.description)
        ),
        .unwrap(item.youtubeID) {
          .iframe(
            .src("https://www.youtube.com/embed/" + $0),
            .allow("accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture"),
            .allowfullscreen(true)
          )
//                        <iframe width="560" height="315" src="https://www.youtube.com/embed/GCQ2JtEuGsI" frameborder="0" allow="accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
        },
        .div(
          .class("summary"),
          .text(item.summary.plainTextShort)
        ),
        .unwrap(item.podcastEpisodeURL) {
          .audio(
            .controls(true),
            .source(
              .src($0)
            )
          )
        },
        .div(
          .class("author"),
          .text("By "),
          .text(item.channel.author),
          .text(" at "),
          .a(
            .href("/channels/" + item.channel.id.uuidString),
            .text(item.channel.siteURL.host ?? item.channel.title)
          ),
          .unwrap(item.channel.twitterHandle) {
            .a(
              .href("https://twitter.com/\($0)"),
              .class("button twitter-handle"),
              .i(.class("el el-twitter")),
              .text(" @\($0)")
            )
          }
        ),
        .div(
          .class("social-share clearfix"),
          .text("Share"),
          .ul(
            .li(
              .a(
                .class("button"),
                .href(item.twitterShareLink),
                .i(.class("el el-twitter")),
                .text(" Tweet")
              )
            )
          )
        )
      )
  }
}

extension String {
  var plainTextShort: String {
    var result: String

    result = trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
    guard result.count > 240 else {
      return result
    }
    return result.prefix(240).components(separatedBy: " ").dropLast().joined(separator: " ").appending("...")
  }
}

extension EntryCategoryType {
  var elClass: String {
    switch self {
    case .companies:
      return "website"
    case .design:
      return "brush"
    case .development:
      return "cogs"
    case .marketing:
      return "bullhorn"
    case .newsletters:
      return "envelope"
    case .podcasts:
      return "podcast"
    case .updates:
      return "file-new"
    case .youtube:
      return "video"
    }
  }
}

extension EntryCategory {
  var elClass: String {
    return type.elClass
  }
}

struct HTMLController {
  func category(req: Request) throws -> EventLoopFuture<HTML> {
    guard let category = req.parameters.get("category") else {
      throw Abort(.notFound)
    }

    return Entry.query(on: req.db)
      .with(\.$channel)
      .join(parent: \.$channel)
      .with(\.$podcastEpisodes)
      .join(children: \.$podcastEpisodes, method: .left)
      .with(\.$youtubeVideos)
      .join(children: \.$youtubeVideos, method: .left)
      .filter(Channel.self, \Channel.$category.$id == category)
      .filter(Channel.self, \Channel.$language.$id == "en")
      .sort(\.$publishedAt, .descending)
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
          .head(withSubtitle: "Swift Articles and News"),
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
                    .li(forEntryItem: $0)
                  }
                )
              )
            )
          )
        )
      }
  }

  func index(req: Request) -> EventLoopFuture<HTML> {
    return Entry.query(on: req.db).join(LatestEntry.self, on: \Entry.$id == \LatestEntry.$id).with(\.$channel)
      .join(parent: \.$channel)
      .with(\.$podcastEpisodes)
      .join(children: \.$podcastEpisodes, method: .left)
      .with(\.$youtubeVideos)
      .join(children: \.$youtubeVideos, method: .left)
      .filter(Channel.self, \Channel.$category.$id != "updates")
      .filter(Channel.self, \Channel.$language.$id == "en")
      .sort(\.$publishedAt, .descending)
      .limit(32)
      .all()
      .flatMapEachThrowing {
        try EntryItem(entry: $0)
      }
      .map { (items) -> HTML in
        HTML(
          .head(withSubtitle: "Swift Articles and News"),
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
                    .li(forEntryItem: $0)
                  }
                )
              )
            )
          )
        )
      }
  }
}

extension HTMLController: RouteCollection {
  func boot(routes: RoutesBuilder) throws {
    routes.get("", use: index)
    routes.get("category", ":category", use: category)
  }
}
