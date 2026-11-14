import MapQuestCore
import SceneKit
import UIKit

/// Sights in the 3D scene: a floating, turning gem on a thin beam above each
/// sight (gold with its name once captured, orange with its name once
/// discovered, a violet "?" once you came near, a grey "?" otherwise); the building of a captured sight is drawn
/// in gold by the scene. Places of remembrance: a still line and their name.
enum SightMarkers3D {
    static let captureStyle = LoD1MeshBuilder.Style(
        discovered: RGBA(1.0, 0.78, 0.26), undiscovered: RGBA(1.0, 0.78, 0.26), roofBrightness: 1.1
    )

    /// The building a sight stands on or in (the tallest whose footprint contains it).
    static func building(at sight: Sight, in buildings: [Building]) -> Building? {
        let point = sight.point
        return buildings
            .filter { $0.bounds.contains(point) && $0.footprint.contains(point) }
            .max { $0.height < $1.height }
    }

    /// The marker of a pin, floating at `height` metres above the ground.
    static func node(for pin: SightPin, x: Float, z: Float, height: Float) -> SCNNode {
        if pin.sight.isPlaceOfRemembrance {
            return remembranceNode(for: pin, x: x, z: z, height: height)
        }
        let container = SCNNode()
        container.position = SCNVector3(x, height, z)

        let material = SCNMaterial()
        if pin.isCaptured {
            material.diffuse.contents = UIColor.captureGold
            material.emission.contents = UIColor(red: 0.45, green: 0.32, blue: 0.05, alpha: 1)
            material.specular.contents = UIColor.white
        } else if pin.isDiscovered {
            material.diffuse.contents = UIColor.systemOrange
            material.emission.contents = UIColor(red: 0.35, green: 0.15, blue: 0.0, alpha: 1)
        } else if pin.isNearby {
            material.diffuse.contents = UIColor.nearbySight
            material.emission.contents = UIColor(red: 0.15, green: 0.1, blue: 0.35, alpha: 1)
        } else {
            material.diffuse.contents = UIColor(white: 0.78, alpha: 1)
            material.transparency = 0.7
        }
        let gem = SCNNode()
        for flipped in [false, true] {
            let pyramid = SCNPyramid(width: 12, height: 10, length: 12)
            pyramid.materials = [material]
            let half = SCNNode(geometry: pyramid)
            if flipped { half.eulerAngles = SCNVector3(Float.pi, 0, 0) }
            gem.addChildNode(half)
        }
        gem.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 6)))
        container.addChildNode(gem)

        let bob = SCNAction.sequence([.moveBy(x: 0, y: 3, z: 0, duration: 1.4), .moveBy(x: 0, y: -3, z: 0, duration: 1.4)])
        bob.timingMode = .easeInEaseOut
        container.runAction(.repeatForever(bob))

        // A thin beam down to the ground.
        let beam = SCNCylinder(radius: 0.6, height: CGFloat(max(height - 10, 1)))
        let beamMaterial = SCNMaterial()
        beamMaterial.diffuse.contents = pin.isCaptured ? UIColor.captureGold.withAlphaComponent(0.45)
            : pin.isDiscovered ? UIColor.systemOrange.withAlphaComponent(0.4)
            : pin.isNearby ? UIColor.nearbySight.withAlphaComponent(0.4) : UIColor(white: 0.8, alpha: 0.3)
        beamMaterial.lightingModel = .constant
        beam.materials = [beamMaterial]
        let beamNode = SCNNode(geometry: beam)
        beamNode.position = SCNVector3(0, -(max(height - 10, 1)) / 2 - 10, 0)
        container.addChildNode(beamNode)

        let text = pin.isDiscovered ? pin.sight.name : "?"
        if let image = label(text) {
            let plane = SCNPlane(width: image.size.width / 4, height: image.size.height / 4)
            let labelMaterial = SCNMaterial()
            labelMaterial.diffuse.contents = image
            labelMaterial.lightingModel = .constant
            labelMaterial.isDoubleSided = true
            plane.materials = [labelMaterial]
            let labelNode = SCNNode(geometry: plane)
            labelNode.position = SCNVector3(0, 17, 0)
            labelNode.constraints = [SCNBillboardConstraint()]
            container.addChildNode(labelNode)
        }
        return container
    }

    /// A place of remembrance: not part of the game – no gem, no motion; a thin,
    /// still line in stone grey and its name.
    static func remembranceNode(for pin: SightPin, x: Float, z: Float, height: Float) -> SCNNode {
        let container = SCNNode()
        container.position = SCNVector3(x, height, z)
        let line = SCNCylinder(radius: 0.4, height: CGFloat(max(height - 6, 1)))
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.remembrance.withAlphaComponent(0.6)
        material.lightingModel = .constant
        line.materials = [material]
        let lineNode = SCNNode(geometry: line)
        lineNode.position = SCNVector3(0, -(max(height - 6, 1)) / 2 - 6, 0)
        container.addChildNode(lineNode)
        if let image = label(pin.sight.name) {
            let plane = SCNPlane(width: image.size.width / 5, height: image.size.height / 5)
            let labelMaterial = SCNMaterial()
            labelMaterial.diffuse.contents = image
            labelMaterial.lightingModel = .constant
            labelMaterial.isDoubleSided = true
            plane.materials = [labelMaterial]
            let labelNode = SCNNode(geometry: plane)
            labelNode.position = SCNVector3(0, 4, 0)
            labelNode.constraints = [SCNBillboardConstraint()]
            container.addChildNode(labelNode)
        }
        return container
    }

    /// The name on a dark rounded background.
    static func label(_ text: String) -> UIImage? {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 34, weight: .bold),
            .foregroundColor: UIColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 18
        let canvas = CGSize(width: ceil(size.width) + 2 * padding, height: ceil(size.height) + padding)
        return UIGraphicsImageRenderer(size: canvas).image { _ in
            UIColor(white: 0, alpha: 0.55).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: canvas.height / 2).fill()
            (text as NSString).draw(at: CGPoint(x: padding, y: padding / 2), withAttributes: attributes)
        }
    }
}
