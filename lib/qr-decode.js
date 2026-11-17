// Prints the text of every QR code in a picture, one per line; nothing when there is none.
// macOS only: Core Image's QR detector, run by osascript -l JavaScript, so nothing is compiled
// or installed. Usage: osascript -l JavaScript qr-decode.js PICTURE
ObjC.import('CoreImage');
ObjC.import('Foundation');
function run(argv) {
  var img = $.CIImage.imageWithContentsOfURL($.NSURL.fileURLWithPath(argv[0]));
  if (!img || img.isNil()) return '';
  var opts = $.NSDictionary.dictionaryWithObjectForKey($.CIDetectorAccuracyHigh, $.CIDetectorAccuracy);
  var found = $.CIDetector.detectorOfTypeContextOptions($.CIDetectorTypeQRCode, $(), opts).featuresInImage(img);
  var out = [];
  for (var i = 0; i < found.count; i++) out.push(ObjC.unwrap(found.objectAtIndex(i).messageString));
  return out.join('\n');
}
