import Queues

struct MediaJob: Job {
  func dequeue(_ context: QueueContext, _: MediaJobConfiguration) -> EventLoopFuture<Void> {
    return context.eventLoop.future()
  }

  typealias Payload = MediaJobConfiguration
}
