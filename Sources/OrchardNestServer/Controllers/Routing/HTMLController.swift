import Fluent
import OrchardNestKit
import Plot
import Vapor

struct HTMLController {
  func index(req: Request) -> EventLoopFuture<HTML> {
    /*
     select * from entries inner join
     (select channel_id, max(published_at) as published_at from entries group by channel_id) latest_entries on entries.channel_id = latest_entries.channel_id and entries.published_at = latest_entries.published_at
     inner join channels on entries.channel_id = channels.id
     order by entries.published_at desc
     */
    return Entry.query(on: req.db)
      .sort(\.$publishedAt, .descending)
      .with(\.$channel)
      .join(Channel.self, on: \Entry.$channel.$id == \Channel.$id)
      .filter(Channel.self, \Channel.$category.$id != "podcast")
      .filter(Channel.self, \Channel.$category.$id != "youtube")
      .filter(Channel.self, \Channel.$category.$id != "newsletters")
      .filter(Channel.self, \Channel.$category.$id != "updates")
      .paginate(for: req)
      .flatMapThrowing { (page: Page<Entry>) -> Page<EntryItem> in
        try page.map { (entry: Entry) -> EntryItem in
          try EntryItem(entry: entry)
        }
      }.map { (page) -> HTML in
        HTML(
          .head(
            .title("OrchardNest"),
            .link(.rel(.stylesheet), .href("/styles/milligram.css"))
          ),
          .body(
            .div(
              .class("container"),
              .div(
                .class("row"),
                .div(
                  .class("column"),
                  .h1("OrchardNest"),
                  .p("Writing HTML in Swift is pretty great!"),
                  .ul(.forEach(page.items) {
                    .li(
                      .class("blog-post"),

                      .a(
                        .href($0.url),
                        .div(
                          .class("title"),
                          .text($0.title)
                        )
                      )
                    )
                  })
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
