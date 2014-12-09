Silk Architecture Overview
=================

#Architecture
Our current architecture is to align three components to hardware vsync timers:

1. Compositor
2. RefreshDriver / Painting
3. Input Events

The flow of our rendering engine is as follows:

1. Hardware Vsync event occurs on an OS specific *Hardware Vsync Thread* on a per monitor basis.
2. For every Firefox window on the specific monitor, notify a **VsyncDispatcher**. The **VsyncDispatcher** is specific to one window.
3. The **VsyncDispatcher** will notify the **Compositor** that a vsync has occured.
4. The **VsyncDispatcher** will then notify the **RefreshDriver** that a vsync has occured.
5. The **Compositor** composites on the *Compositor Thread*, then dispatches input events after a composite.
6. The **RefreshDriver** paints on the *Main Thread*.

The implementation broken into the following sections and will reference this figure. Note that **Objects** are bold fonts while *Threads* are italicized.

<img src="architecture.png" width="900px" height="600px" />

#Hardware Vsync
Hardware vsync events from (1), occur on a specific **Display** Object.
The **Display** object manages and is responsible for enabling / disabling vsync on a per connected display basis.
For example, if two monitors are connected, two **Display** objects will be created, each listening to vsync events for their respective displays.
We require one **Display** object per monitor as each monitor may have different vsync rates or timers.
As a fallback solution, we have one global **Display** object that can synchronize across all connected displays.
The global **Display** is useful if a window is positioned halfway between the two monitors.
Each platform will have to implement a specific **Display** object to hook and listen to vsync events.
As of this writing, both Firefox OS and OS X create their own hardware specific *Hardware Vsync Thread* that executes after a vsync has occured.
OS X creates one *Hardware Vsync Thread* per **CVDisplayLinkRef**.
We create one **CVDisplayLinkRef** per **Display**, thus two **Display** objects will have two independent *Hardware Vsync Threads*.

When a vsync occurs on a **Display**, the *Hardware Vsync Thread* callback fetches all **VsyncDispatchers** associated with the **Display**.
Each **VsyncDispatcher** is notified that a vsync has occured with the vsync's timestamp.
It is the responsibility of the **VsyncDispatcher** to notify other components such as the **Compositor**.

All **Display** objects are encapsulated in a **Vsync Source** object.
The **VsyncSource** object lives in **gfxPlatform** and is instantited only on the parent process when **gfxPlatform** is created.
The **VsyncSource** is destroyed when **gfxPlatform** is destroyed.
There is only one **VsyncSource** object throughout the entire lifetime of Firefox.
Each platform is expected to implement their own **VsyncSource** to manage vsync events.
On Firefox OS, this is through the **HwcComposer2D**.
On OS X, this is through **CVDisplayLinkRef**.
On Windows, it should be through **WaitForVBlank**.

###Multiple Displays
The **VsyncSource** should have an API to switch a **VsyncDispatcher** from one **Display** to another **Display**.
For example, when one window either goes into full screen mode or moves from one connected monitor to another.
When one window moves to another monitor, we expect a platform specific notification to occur.
The detection of when a window enters full screen mode or moves is not covered by Silk itself, but the framework is built to support this use case.
The expected flow is that the OS notification occurs on **nsIWidget**, which retrieves the associated **VsyncDispatcher**.
The **VsyncDispatcher** then notifies the **VsyncSource** to switch the correct **Display** the **VsyncDispatcher** is connected to.
Because the notification works through the **nsIWidget**, the actual switching of the **VsyncDispatcher** to the correct **Display** should occur on the *Main Thread*.

###VsyncDispatcher
The **VsyncDispatcher** executes on the *Hardware Vsync Thread*.
It contains references to the **nsBaseWidget** it is associated with and has a lifetime equal to the **nsBaseWidget**.
The **VsyncDispatcher** is responsible for notifying the various components that a vsync event has occured.
There can be multiple **VsyncDispatchers** per **Display**, one **VsyncDispatcher** per window.
The only responsibility of the **VsyncDispatcher** is to notify components when a vsync event has occured, and to stop listening to vsync when no components require vsync events.
We require one **VsyncDispatcher** per window so that we can handle multiple **Displays**.

#Compositor
When the **VsyncDispatcher** is notified of the vsync event, the **Compositor** associated with the **VsyncDispatcher** begins execution.
Since the **VsyncDispatcher** executes on the *Hardware Vsync Thread* and the **Compositor** composites on the *CompositorThread*, the **Compositor** posts a task to the *CompositorThread*.
Thus the **VsyncDispatcher** notifies the **Compositor**, which then schedules the task on the appropriate thread.
The model where the **VsyncDispatcher** notifies components on the *Hardware Vsync Thread*, and the component schedules the task on the appropriarate thread is used everywhere.

The **Compositor** listens to vsync events as needed and stops listening to vsync when composites are no longer scheduled or required.
Every **CompositorParent** is associated and tied to one **VsyncDispatcher**.
Each **CompositorParent** is associated with one widget and is created when a new platform window or **nsBaseWidget** is created.
The **CompositorParent**, **VsyncDispatcher**, and **nsBaseWidget** all have the same lifetimes, which are created and destroyed together.

###Widget, Compositor, VsyncDispatcher Shutdown Procedure
Shutdown Process

When the [nsBaseWidget's destructor runs](http://dxr.mozilla.org/mozilla-central/source/widget/nsBaseWidget.cpp?from=nsBaseWidget.cpp#221) - It calls nsBaseWidget::DestroyCompositor on the *Gecko Main Thread*. The main issue is that we destroy the Compositor through the nsBaseWidget, so the widget will not be kept alive by the nsRefPtr on the CompositorVsyncObserver.

During nsBaseWidget::DestroyCompositor, we first destroy the CompositorChild. This sends a sync IPC call to CompositorParent::RecvStop, which calls [CompositorParent::Destroy](http://dxr.mozilla.org/mozilla-central/source/gfx/layers/ipc/CompositorParent.cpp?from=CompositorParent.cpp#474). During this time, the *main thread* is blocked on the parent process. CompositorParent::Destroy runs on the *Compositor thread* and cleans up some resources, including setting the CompositorVsyncObserver to nullptr. CompositorParent::Destroy also explicitly keeps the CompositorParent alive and posts another task to run CompositorParent::DeferredDestroy on the Compositor loop so that all ipdl code can finish executing.

Once CompositorParent::RecvStop finishes, the *main thread* in the parent process continues destroying nsBaseWidget. nsBaseWidget posts another task to [DeferedDestroyCompositor on the main thread](http://dxr.mozilla.org/mozilla-central/source/widget/nsBaseWidget.cpp#168). At the same time, the *Compositor thread* is executing tasks until CompositorParent::DeferredDestroy runs. Now we have a two tasks as both the nsBaseWidget:DeferredDestroyCompositor releases a reference to the Compositor on the *main thread* and the CompositorParent::DeferredDestroy releases a reference to the Compositor on the *compositor thread*. Finally, the CompositorParent itself is destroyed on the *main thread* once both deferred destroy's execute.

With the CompositorVsyncObserver, any accesses to the widget after nsBaseWidget::~nsBaseWidget executes are invalid. While the sync call to CompositorParent::RecvStop executes, we set the CompositorVsyncObserver to null. If the CompositorVsyncObserver's vsync notification executes on the *hardware vsync thread*, it will post a task to the Compositor loop and reference an invalid widget. In addition, posting a task to the CompositorLoop would also be invalid as we could destroy the Compositor before the Vsync's tasks executes. Any accesses to the widget between the time the nsBaseWidget's destructor runs and the CompositorVsyncObserver's destructor runs on the *main thread* aren't safe yet a hardware vsync event could occur between these times. Thus, we explicitly shut down vsync events in the **VsyncDispatcher** during nsBaseWidget destruction.

#Input Events
One large goal of Silk is to align touch events with vsync events.
On Firefox OS, touchscreens often have different touch scan rates than the display refreshes.
A Flame device has a touch refresh rate of 75 HZ, while a Nexus 4 has a touch refresh rate of 100 HZ, while the device's display refresh rate is 60HZ.
When a vsync event occurs, we resample touch events then dispatch the resampled touch event to APZ.
Touch events on Firefox OS occur on a *Touch Input Thread* whereas they are processed by APZ on the *Gecko Main Thread*.
Until APZ can process touch events on another *APZ Input Thread*, we will be bottlenecked for truly smooth scrolling.
We use [Google Android's touch resampling](http://www.masonchang.com/blog/2014/8/25/androids-touch-resampling-algorithm) algorithm to resample touch events.

Currently, we have a strict ordering between Composites and touch events.
When a touch event occurs on the *Touch Input Thread*, we store the touch event in a queue.
When a vsync event occurs, the **VsyncDispatcher** notifies the **Compositor** of a vsync event.
Once the **Compositor** finishes compositing, it then notifies the **GeckoTouchDispatcher**, which processes the touch event.
We require this strict ordering because if a vsync notification is dispatched to both the **Compositor** and **GeckoTouchDispatcher** at the same time, a race condition occurs between processing the touch event and therefore position versus compositing.
In practice, this creates very janky scrolling.

Once touch events can be processed off the *Gecko Main Thread*, we can inverse this ordering so remove one frame of latency.
Touch events can be processed on the *APZ Input Thread*, which then notifies the **Compositor** to composite with the latest touch input data.
As of this writing, we have not analyzed input events on desktop platforms.

One slight quirk is that input events can start a composite, for example during a scroll and after the **Compositor** is no longer listening to vsync events.
In these cases, we have to dispatch vsync events to the **GeckoTouchDispatcher** so that the touch events are processed.
If touch events were not dispatched, and since the **Compositor** is not listening to vsync events, the touch events would never be dispatched.
This corner case is handled in the **VsyncDispatcher**.

#Refresh Driver

###Firefox OS
Here we go

###E10s
Silk with e10s

#Object Lifetime
Object lifetime

#Threads
The model where the **VsyncDispatcher** notifies components on the *Hardware Vsync Thread*, and the component schedules the task on the appropriarate thread is used everywhere.

1. Compositor Thread
2. Main Thread
3. PBackground Thread
4. Hardware Vsync Thread
5. APZ Input Thread

#Gaming

#Performance
Vsync Timers

