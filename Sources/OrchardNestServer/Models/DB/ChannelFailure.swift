import Fluent
import Vapor

import Foundation
public protocol DatabaseEnum: CaseIterable {
  static var schema: String { get }
  static func rawValue(_ case: Self) -> String
}

enum ChannelFailureType : String, DatabaseEnum, Codable {
  static var schema: String = "channel_failure_type"
  
  static func rawValue(_ case: ChannelFailureType) -> String {
    `case`.rawValue
  }
  
  case missing
  case download
  case decoding
}

final class ChannelFailure: Model {
  init() {
    
  }
  
  static var schema = "channel_failures"

  init(channelId: UUID, type: ChannelFailureType, failure: Error) {
    self.id = channelId
    self.type = type
    self.description = failure.localizedDescription
  }
  

  @ID(custom: "channel_id", generatedBy: .user)
  var id: UUID?
  
  @Enum(key: "type")
  var type: ChannelFailureType
  
  @Field(key: "description")
  var description: String
  
  @Timestamp(key: "created_at", on: .create)
  var createdAt: Date?

  @Parent(key: "channel_id")
  var channel: Channel
}



