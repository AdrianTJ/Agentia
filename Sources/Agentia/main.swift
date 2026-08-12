import AgentiaUI

// The whole app lives in AgentiaUI, and this executable is the four lines that
// start it.
//
// It was all one executable target until a round of visual bugs shipped: the
// sidebar drawn underneath the traffic lights, and the rendered view showing a
// document as empty while the reader was looking at their own unsaved text in
// the editor. Both were plain logic, and neither was caught, because nothing in
// an executable target with @main can be imported by a test.
//
// The window, its layout, and the view-mode machinery are now in a library that
// AgentiaUITests can drive directly.
AgentiaApp.main()
