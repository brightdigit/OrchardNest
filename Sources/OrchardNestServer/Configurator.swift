import Fluent
import FluentPostgresDriver
import OrchardNestKit
import QueuesFluentDriver
import Vapor

typealias OrganizedSite = (String, String, Site)

//
public final class Configurator: ConfiguratorProtocol {
  public static let shared: ConfiguratorProtocol = Configurator()

  //
  ///// Called before your application initializes.
  public func configure(_ app: Application) throws {
    // Register providers first
    // try services.register(FluentPostgreSQLProvider())
    // try services.register(AuthenticationProvider())

    // services.register(DirectoryIndexMiddleware.self)

    // Register middleware
    // var middlewares = MiddlewareConfig() // Create _empty_ middleware config
    // middlewares.use(SessionsMiddleware.self) // Enables sessions.
    // let rootPath = Environment.get("ROOT_PATH") ?? app.directory.publicDirectory

//    app.webSockets = WebSocketRepository()
//
//    app.middleware.use(DirectoryIndexMiddleware(publicDirectory: rootPath))

    app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    // middlewares.use(ErrorMiddleware.self) // Catches errors and converts to HTTP response
    // services.register(middlewares)

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
      JobModelMigrate(schema: "queue_jobs")
    ])

    app.queues.configuration.refreshInterval = .seconds(25)
    app.queues.use(.fluent())
//    app.databases.middleware.use(UserEmailerMiddleware(app: app))
//
//    app.migrations.add(CreateDevice())
//    app.migrations.add(CreateAppleUser())
//    app.migrations.add(CreateDeviceWorkout())
//    app.migrations.add(ActivateWorkout())
    // let wss = NIOWebSocketServer.default()

//    app.webSocket("api", "v1", "workouts", ":id", "listen") { req, websocket in
//      guard let idData = try? Base32CrockfordEncoding.encoding.decode(base32Encoded: req.parameters.get("id")!) else {
//        return
//      }
//      let workoutID = UUID(data: idData)
//
//      _ = Workout.find(workoutID, on: req.db).unwrap(or: Abort(HTTPResponseStatus.notFound)).flatMapThrowing { workout in
//        let workoutId = try workout.requireID()
//        app.webSockets.save(websocket, withID: workoutId)
//      }
//    }

    app.queues.add(RefreshJob())
    try app.queues.startInProcessJobs(on: .default)
    app.commands.use(RefreshCommand(help: "Imports data into the database"), as: "refresh")

    try app.autoMigrate().wait()
    //   services.register(wss, as: WebSocketServer.self)
//    app.get { req in
//      req.queue.dispatch(
//        RefreshJob.self,
//        RefreshConfiguration()
//      ).map { "Hello" }
//    }

    let api = app.grouped("api", "v1")
    try api.grouped("entires").register(collection: EntryController())
  }
}
