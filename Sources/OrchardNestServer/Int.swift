import Foundation

extension Int {
  func asString(style: DateComponentsFormatter.UnitsStyle) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = style

    guard let formattedString = formatter.string(from: Double(self)) else { return "" }
    return formattedString
  }
}
