import SwiftUI
import MapKit

final class MealAnnotation: NSObject, MKAnnotation {
    let meal: Meal
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { meal.displayDish }
    var subtitle: String? { meal.placeName }
    init(meal: Meal, coordinate: CLLocationCoordinate2D) {
        self.meal = meal; self.coordinate = coordinate
    }
}

struct MealMapView: View {
    @EnvironmentObject var store: MealStore
    @State private var selected: Meal?

    var body: some View {
        NavigationStack {
            ClusterMap(meals: store.meals) { selected = $0 }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("マップ")
                .navigationBarTitleDisplayMode(.inline)
                .sheet(item: $selected) { m in
                    NavigationStack { MealDetailView(mealId: m.id) }
                        .presentationDetents([.medium, .large])
                }
        }
    }
}

struct ClusterMap: UIViewRepresentable {
    let meals: [Meal]
    let onSelect: (Meal) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.register(MealAnnotationView.self, forAnnotationViewWithReuseIdentifier: MealAnnotationView.reuseID)
        map.register(MealClusterView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        let existing = map.annotations.compactMap { $0 as? MealAnnotation }
        let newMeals = meals.filter { $0.coordinate != nil }
        let changed = existing.count != newMeals.count
            || zip(existing.map(\.meal).sorted { $0.id < $1.id }, newMeals.sorted { $0.id < $1.id }).contains { $0 != $1 }
        guard changed else { return }
        map.removeAnnotations(existing)
        let anns = newMeals.map { MealAnnotation(meal: $0, coordinate: $0.coordinate!) }
        map.addAnnotations(anns)
        if !context.coordinator.didFit, !anns.isEmpty {
            context.coordinator.didFit = true
            map.showAnnotations(anns, animated: false)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ClusterMap
        var didFit = false
        init(_ p: ClusterMap) { parent = p }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MealAnnotation {
                return mapView.dequeueReusableAnnotationView(withIdentifier: MealAnnotationView.reuseID, for: annotation)
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let a = view.annotation as? MealAnnotation {
                parent.onSelect(a.meal)
                mapView.deselectAnnotation(a, animated: false)
            } else if let c = view.annotation as? MKClusterAnnotation {
                mapView.showAnnotations(c.memberAnnotations, animated: true)
            }
        }
    }
}

final class MealAnnotationView: MKAnnotationView {
    static let reuseID = "meal"
    private let imageView = UIImageView()
    private var task: Task<Void, Never>?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = "meal"
        frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        centerOffset = CGPoint(x: 0, y: -24)
        imageView.frame = bounds
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 10
        imageView.layer.borderWidth = 2
        imageView.layer.borderColor = UIColor.white.cgColor
        imageView.backgroundColor = .systemGray5
        addSubview(imageView)
        layer.shadowOpacity = 0.3; layer.shadowRadius = 3; layer.shadowOffset = .init(width: 0, height: 1)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var annotation: MKAnnotation? {
        didSet {
            clusteringIdentifier = "meal"
            task?.cancel()
            imageView.image = nil
            guard let a = annotation as? MealAnnotation else { return }
            let path = a.meal.photoPath
            task = Task { @MainActor [weak self] in
                let img = await ImageCache.shared.image(path: path)
                if !Task.isCancelled { self?.imageView.image = img }
            }
        }
    }
}

final class MealClusterView: MKMarkerAnnotationView {
    override var annotation: MKAnnotation? {
        didSet {
            markerTintColor = .systemOrange
            glyphText = (annotation as? MKClusterAnnotation).map { "\($0.memberAnnotations.count)" }
            displayPriority = .defaultHigh
        }
    }
}
