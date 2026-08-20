import Cocoa

// Une seule instance a la fois. Deux copies du bundle qui tournent en meme temps
// (celle de /Applications lancee au login et celle d'un build local, par exemple)
// installent deux moniteurs de raccourci global : la dictee part en double et le
// texte est colle deux fois. La verification doit preceder app.run().
SingleInstance.enforce()

// Le point d'entree d'un `main.swift` n'est pas isole, alors que l'AppDelegate vit
// sur le main thread. On l'affirme au compilateur : a cet instant, un seul thread
// s'execute et c'est le principal.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Retenu explicitement : NSApplication ne garde qu'une reference faible sur son
    // delegate, qui serait donc libere des la sortie de ce bloc.
    objc_setAssociatedObject(app, "fr.charlesneveu.voxprompt.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.setActivationPolicy(.accessory)
    app.run()
}
