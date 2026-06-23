import CarPlay
import Foundation

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let environment = SharedAppEnvironment.shared
        let coordinator = CarPlayCoordinator(
            interfaceController: interfaceController,
            store: environment.store,
            player: environment.player
        )
        self.coordinator = coordinator
        coordinator.connect()
    }

}

extension CarPlaySceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        coordinator?.disconnect()
        coordinator = nil
    }
}
