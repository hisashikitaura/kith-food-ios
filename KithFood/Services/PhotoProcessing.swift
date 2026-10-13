import Foundation
import UIKit
import Photos
import ImageIO
import CoreLocation

struct PhotoInfo {
    var date: Date?
    var location: CLLocationCoordinate2D?
}

enum PhotoProcessing {
    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Location/date from PHAsset (preferred), falling back to EXIF in the raw data.
    static func info(localIdentifier: String?, data: Data) -> PhotoInfo {
        var info = PhotoInfo()
        if let id = localIdentifier,
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
            info.date = asset.creationDate
            info.location = asset.location?.coordinate
        }
        if info.date == nil || info.location == nil,
           let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if info.location == nil, let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
               var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
               var lng = gps[kCGImagePropertyGPSLongitude] as? Double {
                if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
                if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lng = -lng }
                info.location = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            }
            if info.date == nil, let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                info.date = f.date(from: s)
            }
        }
        return info
    }

    /// Re-renders the image (max 1600px). The new JPEG carries no EXIF/GPS metadata.
    static func strippedJPEG(from data: Data, maxSide: CGFloat = 1600) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = UIImage(cgImage: cg)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: img.size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: img.size))
        }
        return out.jpegData(compressionQuality: 0.8)
    }
}
