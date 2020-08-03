import Fluent
import FluentSQL
import OrchardNestKit
import Plot
import Vapor

struct InvalidDatabaseError: Error {}

extension String {
  var plainTextShort: String {
    var result : String
    
    result = replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
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
  func index(req: Request) -> EventLoopFuture<HTML> {
    /*
     select * from entries inner join
     (select channel_id, max(published_at) as published_at from entries group by channel_id) latest_entries on entries.channel_id = latest_entries.channel_id and entries.published_at = latest_entries.published_at
     inner join channels on entries.channel_id = channels.id
     order by entries.published_at desc
     */

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
      .map { (page) -> HTML in
        HTML(
          .head(
            .title("OrchardNest - Swift Articles and News"),
            .meta(.charset(.utf8)),
//            <link rel="stylesheet" type="text/css" href="/styles/elusive-icons/css/elusive-icons.min.css"/>
//                <link rel="stylesheet" type="text/css" href="/styles/normalize.css"/>
//                <link rel="stylesheet" type="text/css" href="/styles/milligram.css"/>
//                <link rel="stylesheet" type="text/css" href="/styles/style.css">
//                <link href="https://fonts.googleapis.com/css2?family=Catamaran:wght@100;400;800&display=swap" rel="stylesheet">
            .link(.rel(.stylesheet), .href("/styles/elusive-icons/css/elusive-icons.min.css")),

            .link(.rel(.stylesheet), .href("/styles/normalize.css")),

            .link(.rel(.stylesheet), .href("/styles/milligram.css")),
            .link(.rel(.stylesheet), .href("/styles/style.css")),
            .link(.rel(.stylesheet), .href("https://fonts.googleapis.com/css2?family=Catamaran:wght@100;400;800&display=swap"))
          ),
          .body(
            .div(
              .class("container"),
              .div(
                .class("row"),
                .div(
                  .class("column"),
                  .h1("OrchardNest"),
                  .p("Swift Articles and News"),

                  .ul(
                    .class("articles"),
                    .forEach(page) {
                      /*
                       <li class="blog-post">
                                     <a class="title" href="#"><h3><i class="el el-website"></i> Swift: Property wrappers</h3></a>
                                     <div class="publishedAt">Published July 31, 2020</div>
                                     <div class="summary">
                                       Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Phasellus vestibulum lorem sed risus ultricies tristique nulla aliquet.
                                     </div>
                                     <div class="author">By John Doe at <a href="/sites/">swiftui.com</a></div>
                                   </li>
                       */
                      .li(
                        .class("blog-post"),

                        .a(
                          .href($0.url),
                          .class("title"),
                          .h3(
                            .i(.class("el el-\($0.category.elClass)")),

                            .text($0.title)
                          )
                        ),
                        .div(
                          .class("publishedAt"),
                          .text($0.publishedAt.description)
                        ),
                        .unwrap($0.youtubeID) {
                          .iframe(
                            .src("https://www.youtube.com/embed/" + $0)
                          )
//                        <iframe width="560" height="315" src="https://www.youtube.com/embed/GCQ2JtEuGsI" frameborder="0" allow="accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
                        },
                        .div(
                          .class("summary"),
                          .text($0.summary.plainTextShort)
                        ),
                        .unwrap($0.podcastEpisodeURL) {
                          .audio(
                            .controls(true),
                            .source(
                              .src($0)
                            )
                          )
//                        <audio controls>
//                         <source src="http://media.w3.org/2010/07/bunny/04-Death_Becomes_Fur.mp4"
//                                 type='audio/mp4'>
//                         <!-- The next two lines are only executed if the browser doesn't support MP4 files -->
//                         <source src="http://media.w3.org/2010/07/bunny/04-Death_Becomes_Fur.oga"
//                                 type='audio/ogg; codecs=vorbis'>
//                         <!-- The next line will only be executed if the browser doesn't support the <audio> tag-->
//                         <p>Your user agent does not support the HTML5 Audio element.</p>
//                        </audio>
                        },
                        .div(
                          .class("author"),
                          .text("By "),
                          .text($0.channel.author),
                          .text(" at "),
                          .a(
                            .href("/channels/" + $0.channel.id.uuidString),
                            .text($0.channel.siteURL.host ?? $0.channel.title)
                          )
                        )
                      )
                    }
                  )
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
  }
}
