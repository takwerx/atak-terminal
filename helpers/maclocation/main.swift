// maclocation: print this Mac's position as "lat,lon,accuracy_m" using CoreLocation,
// the same Wi-Fi based positioning a browser uses. Exits 1 with a message on failure.
import CoreLocation
import Foundation

final class Once: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    var done = false
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }
    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last, !done else { return }
        done = true
        print(String(format: "%.6f,%.6f,%.0f", l.coordinate.latitude, l.coordinate.longitude, l.horizontalAccuracy))
        exit(0)
    }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {
        FileHandle.standardError.write("location failed: \(e.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .denied || m.authorizationStatus == .restricted {
            FileHandle.standardError.write("location permission denied; allow it in System Settings > Privacy & Security > Location Services\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
let once = Once()
once.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    FileHandle.standardError.write("no location within 20 seconds\n".data(using: .utf8)!)
    exit(1)
}
RunLoop.main.run()
