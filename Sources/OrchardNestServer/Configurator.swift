import Fluent
import FluentPostgresDriver
import Ink
import OrchardNestKit
import Plot
import QueuesFluentDriver
import Vapor
extension Date {
  func get(_ type: Calendar.Component) -> Int {
    let calendar = Calendar.current
    return calendar.component(type, from: self)
  }
}

//
public final class Configurator: ConfiguratorProtocol {
  public static let shared: ConfiguratorProtocol = Configurator()

  //
  ///// Called before your application initializes.
  public func configure(_ app: Application) throws {
    app.commands.use(RefreshCommand(help: "Imports data into the database"), as: "refresh")
    let html = HTMLController(markdownDirectory: app.directory.viewsDirectory)
    app.middleware = .init()
    app.middleware.use(ErrorPageMiddleware(htmlController: html))
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Configure a SQLite database
    let postgreSQLConfig: PostgresConfiguration

    if let url = Environment.get("DATABASE_URL") {
      postgreSQLConfig = PostgresConfiguration(url: url)!
    } else {
      postgreSQLConfig = PostgresConfiguration(hostname: "localhost", username: "orchardnest")
    }

    app.databases.use(.postgres(configuration: postgreSQLConfig, maxConnectionsPerEventLoop: 8, connectionPoolTimeout: .seconds(60)), as: .psql)
    app.migrations.add([
      CategoryMigration(),
      LanguageMigration(),
      CategoryTitleMigration(),
      ChannelMigration(),
      EntryMigration(),
      PodcastEpisodeMigration(),
      YouTubeChannelMigration(),
      YouTubeVideoMigration(),
      PodcastChannelMigration(),
      ChannelStatusMigration(),
      LatestEntriesMigration(),
      JobModelMigrate(schema: "queue_jobs")
    ])

    try app.autoMigrate().wait()

    if CommandLine.arguments.contains("refresh") {
      return
    }

    app.queues.configuration.refreshInterval = .seconds(25)
    app.queues.use(.fluent())

    app.queues.add(DirectoryJob())
    app.queues.schedule(RefreshScheduledJob()).daily().at(.midnight)
    app.queues.schedule(RefreshScheduledJob()).daily().at(7, 30)
    app.queues.schedule(RefreshScheduledJob()).daily().at(19, 30)
    #if DEBUG
      if !app.environment.isRelease {
        let minute = Date().get(.minute)
        [0, 30].map { ($0 + minute + 1).remainderReportingOverflow(dividingBy: 60).partialValue }.forEach { minute in
          app.queues.schedule(RefreshScheduledJob()).hourly().at(.init(integerLiteral: minute))
        }
      }
    #endif

    let api = app.grouped("api", "v1")

    try app.register(collection: html)
    try api.grouped("entires").register(collection: EntryController())
    try api.grouped("channels").register(collection: ChannelController())
    try api.grouped("categories").register(collection: CategoryController())

    app.post("jobs") { req in
      req.queue.dispatch(
        DirectoryJob.self,
        DirectoryConfiguration()
      ).map { HTTPStatus.created }
    }

    if CommandLine.arguments.contains("queues") {
      app.logger.info("Starting Scheduled Jobs")
      try app.queues.startScheduledJobs()
    }
  }
}
