import CoreLocation
import Foundation

/// Where the sun was in the sky, worked out from a date and place. Accurate to about a degree,
/// which is plenty to tell a sunrise or sunset from midday.
enum SunPosition {
    /// The sun's height above the horizon in degrees: negative once it has set.
    static func elevation(at date: Date, coordinate: CLLocationCoordinate2D) -> Double {
        let rad = Double.pi / 180
        // Days since noon on 1 January 2000.
        let d = date.timeIntervalSince1970 / 86_400 - 10_957.5
        let meanAnomaly = (357.529 + 0.98560028 * d) * rad
        let meanLongitude = 280.459 + 0.98564736 * d
        let longitude = (meanLongitude + 1.915 * sin(meanAnomaly) + 0.020 * sin(2 * meanAnomaly)) * rad
        let tilt = (23.439 - 0.00000036 * d) * rad
        let rightAscension = atan2(cos(tilt) * sin(longitude), cos(longitude))
        let declination = asin(sin(tilt) * sin(longitude))
        let siderealHours = (18.697374558 + 24.06570982441908 * d).truncatingRemainder(dividingBy: 24)
        let hourAngle = (siderealHours * 15 + coordinate.longitude) * rad - rightAscension
        let latitude = coordinate.latitude * rad
        let height = sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle)
        return asin(max(-1, min(1, height))) / rad
    }

    /// Whether the sun was low: from a little before sunrise or after sunset to about eight degrees up.
    static func isGoldenHour(at date: Date, coordinate: CLLocationCoordinate2D) -> Bool {
        (-4...8).contains(elevation(at: date, coordinate: coordinate))
    }
}
