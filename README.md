# TravelPicks

An iOS app (SwiftUI, iOS 26) for turning trips into photo collections and printed books. You add trips from your Photos library; they show as cards, as pins on a map, and as books. Adding media opens the TravelPicks image picker, which sorts the library into trips, places, days and weeks and picks the best shots. The picker is built to run on the Eye image model, which is in beta. Until Eye ships, Apple's Vision framework stands in for it.

## Run it

Open `TravelPicks.xcodeproj`, choose your iPhone as the run destination, and press Run. Signing uses your Personal Team.

## How it works

- `Home/` is the app: the Trips, Map and Books tabs, the trip story screen and the book preview. `Model/TripStore.swift` saves the trips you add. A saved trip points at photos in the library; it doesn't copy them.
- `Picker/` is the image picker. `MediaPicker` presents it as a sheet and returns the ticked items.
- `Library/TripFinder.swift` finds home (the place you photograph on the most days). A trip is a run of photos taken more than 60km from home. It ends at the first photo taken back home, or after a week with no photos away.
- `Library/PlaceNamer.swift` names cities and places with the system geocoder and caches the results.
- `Eye/EyeModel.swift` is the contract: each photo gets tags, a 0 to 1 score and an optional discard reason.
- `Eye/PreviewEye.swift` is the stand-in for Eye. It uses Vision to classify scenes, find faces and closed eyes, and score photos. It also checks sharpness and exposure on each image, and finds duplicates by comparing each photo with the one taken before it.
- `Eye/Curator.swift` runs the model, caches its results, and stores what you restore or discard. Nothing is deleted from Photos.

## Eye

The picker runs the Eye model from Desert Ant Labs (`desert-ant-core` 4.0, product `Eye`). `Eye/DesertAntEye.swift` maps its tags, keeper score and duplicate groups onto the picker's chips and discard reasons. The model downloads when the app launches (about 50MB, cached after the first time). When the picker opens, `Curator.curateLibrary()` works through the library newest first, 1,000 photos at a time, saving as it goes so a later run picks up where it stopped. If Eye can't download, `Eye/PreviewEye.swift` (Apple's Vision framework) does the work instead.
