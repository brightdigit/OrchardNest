
import Foundation

extension TimeInterval {
    static let second = 1.0
    static let minute = 60 * TimeInterval.second
    static let hour = 60 * TimeInterval.minute
    static let day = 24 * TimeInterval.hour
    static let week = 7 * TimeInterval.day
    static let month = 30 * TimeInterval.day
    static let year = 365.25 * TimeInterval.day
}

struct ComponentDuration {
    let duration:Int
    let component:Calendar.Component
}

public enum Errors:Error {
    case notBeginWithP
    case timePartNotBeginWithT
    case unknownElement
    case discontinuous

}
enum Component {
    case second
    case minute
    case hour
    case day
    case week
    case month
    case year
    
    func timeInterval() -> TimeInterval {
        switch self {
        case .second:
            return .second
        case .minute:
            return .minute
        case .hour:
            return .hour
        case .day:
            return .day
        case .week:
            return .week
        case .month:
            return .month
        case .year:
            return .year
        }
    }
    
    func stepDown() -> (duration:Int, component:Component) {
        switch self {
        case .year:
            return (duration: 12, component:.month)
        case .month:
            return (duration: 30, component:.day)
        case .week:
            return (duration: 7, component:.day)
        case .day:
            return (duration: 24, component:.hour)
        case .hour:
            return (duration: 60, component:.minute)
        case .minute:
            return  (duration:60, component:.second)
        case .second:
            return (duration: 1, component:.second)
        }
    }
    
    func toCalendarComponent() -> Calendar.Component {
        switch self {
        case .year:
            return .year
        case .month:
            return .month
        case .week:
            return .day
        case .day:
            return .day
        case .hour:
            return .hour
        case .minute:
            return .minute
        case .second:
            return .second
        }
    }
    
    func value(duration:Double) -> [ComponentDuration] {
        var correctedDuration = duration
        if self == .week {
            correctedDuration *= 7
        }
        let intValue = Int(correctedDuration.rounded(.down))
        var output:[ComponentDuration] = []
        
        output.append(ComponentDuration(duration: intValue, component: self.toCalendarComponent()))
        let remainedDuration =  duration - Double(intValue)
        if remainedDuration > 0.0001 {
            let step = self.stepDown()
            let recalculatedRemainedDuration =  Double(step.duration) * remainedDuration
            let intRecalculatedRemainedDuration = Int(recalculatedRemainedDuration.rounded(.down))
            output.append(ComponentDuration(duration: intRecalculatedRemainedDuration, component: step.component.toCalendarComponent()))
        }
        return output
    }
}

extension TimeInterval {
  init(iso8601: String) throws {
    let value = iso8601
    guard value.hasPrefix("P") else {
               throw Errors.notBeginWithP
           }
           //originalValue = value
           var timeInterval:TimeInterval = 0
           var numberValue:String = ""
           let numbers = Set("0123456789.,")
           var isTimePart = false
           
    var dateComponents = DateComponents(calendar: Calendar.current, timeZone: TimeZone.current, era: nil, year: 0, month: 0, day: 0, hour: 0, minute: 0, second: 0, nanosecond: nil, weekday: nil, weekdayOrdinal: nil, quarter: nil, weekOfMonth: nil, weekOfYear: nil, yearForWeekOfYear: nil)
           
           func addTimeInterval(base:Component) {
               guard let value = Double(numberValue.replacingOccurrences(of: ",", with: ".")) else {
                   numberValue = ""
                   return
               }
               timeInterval += value * base.timeInterval()
               numberValue = ""
               
               let components = base.value(duration: value)
               for component in components {
                   var currentValue = dateComponents.value(for: component.component) ?? 0
                   currentValue += component.duration
                   dateComponents.setValue(currentValue, for: component.component)
               }
               
           }
           
           for char in value {
               switch char {
               case "P":
                   continue
               case "T":
                   isTimePart = true
               case _ where numbers.contains(char):
                   numberValue.append(char)
               case "D":
                   addTimeInterval(base: .day)
               case "Y":
                   addTimeInterval(base: .year)
               case "M":
                   if isTimePart {
                       addTimeInterval(base: .minute)
                   } else {
                       addTimeInterval(base: .month)
                   }
               case "W":
                   addTimeInterval(base: .week)
               case "H":
                   if isTimePart {
                       addTimeInterval(base: .hour)
                   } else {
                       throw Errors.timePartNotBeginWithT
                   }
               case "S":
                   if isTimePart {
                       addTimeInterval(base: .second)
                   } else {
                       throw Errors.timePartNotBeginWithT
                   }
               default:
                   throw Errors.unknownElement
               }
           }
           if numberValue.count > 0 {
               throw Errors.discontinuous
           }
           self = timeInterval
  }
}

//let json = """
//{
//  "items": [
//    {
//      "id": "Ks-_Mh1QhMc",
//      "contentDetails": {
//        "duration": "PT21M3S"
//      }
//    }
//  ]
//}
//"""

//let decoder = JSONDecoder()
//decoder.dateDecodingStrategy = .iso8601
//
//let data = json.data(using: .utf8)!

struct YouTubeItemContentDetails : Decodable {
  let duration: TimeInterval
  
  enum CodingKeys : String, CodingKey {
    case duration
  }
  
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let durationString = try container.decode(String.self, forKey: .duration)
    self.duration = try TimeInterval(iso8601: durationString)
  }
  
}

struct YouTubeItem  : Decodable {
  let contentDetails : YouTubeItemContentDetails
  let id : String
}

struct YouTubeResponse  : Decodable {
  let items : [YouTubeItem]
}

//let result = Result{try decoder.decode(YouTubeResponse.self, from: data)}
//print(result)

