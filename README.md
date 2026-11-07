# MapQuest

MapQuest is an iPhone app that combines a classic map with a *fog of war*:
you only see the parts of the world you have actually been to. Everything
else stays visibly darker until you go there. The first play area is
Berlin; the data model is global.

The app has three major components:

| Component | Responsibility |
|---|---|
| **Location tracking** | Continuously observes the user's position, but stores only the positions that reveal new parts of the map (latitude, longitude, height, timestamp) |
| **Discovered area** | Turns stored positions into discovered-area polygons, merges adjacent areas into regions, keeps disconnected areas apart; it is a cache that can always be rebuilt from the positions |
| **Map display** | 2D: MapKit with a translucent fog overlay and the discovered area cut out. 3D: buildings that block the view; seen buildings are revealed |

## Documentation

* [Literature review and design decisions](docs/01-literature-review.md)

## Status

- [x] Literature review
- [ ] Data model (location data) for 2D + 3D
- [ ] Location data component and discovered-area component (2D)
- [ ] 2D map presentation
- [ ] Berlin 2D data
- [ ] Location data component and discovered-area component (3D)
- [ ] 3D map presentation
- [ ] Berlin 3D data
