Silk Architecture Overview
=================

#Architecture
Our current architecture is to align three components to hardware vsync timers:

1. Compositor
2. RefreshDriver / Painting
3. Input Events

The flow of our rendering engine is as follows:

1. Hardware Vsync event occurs on an OS specific *Hardware Vsync Thread* on a per monitor basis.
2. For every Firefox window on the specific monitor, notify a **CompositorVsyncDispatcher**. The **CompositorVsyncDispatcher** is specific to one window.
3. The **CompositorVsyncDispatcher** will notify the **Compositor** that a vsync has occured.
4. The **RefreshTimerVsyncDispatcher** will then notify the Chrome **RefreshTimer** that a vsync has occured.
5. The **RefreshTimerVsyncDispatcher** will send IPC messages to all content processes to tick their respective active **RefreshTimer**.
6. The **Compositor** composites on the *Compositor Thread*, then dispatches input events after a composite.
7. The **RefreshDriver** paints on the *Main Thread*.

The implementation broken into the following sections and will reference this figure. Note that **Objects** are bold fonts while *Threads* are italicized.

<img src="architecture.png" width="900px" height="630px" />

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
On Windows, we have to create a new platform *thread* that waits for DwmFlush().
Once the thread wakes up from DwmFlush(), the actual vsync timestamp is retrieved from DwmGetCompositionTimingInfo(), which is the timestamp that is actually passed into the compositor and refresh driver.

When a vsync occurs on a **Display**, the *Hardware Vsync Thread* callback fetches all **CompositorVsyncDispatchers** associated with the **Display**.
Each **CompositorVsyncDispatcher** is notified that a vsync has occured with the vsync's timestamp.
It is the responsibility of the **CompositorVsyncDispatcher** to notify other components such as the **Compositor**.
The **Display** will then notify the associated **RefreshTimerVsyncDispatcher**, which should notify all active **RefreshDrivers** to tick.

All **Display** objects are encapsulated in a **Vsync Source** object.
The **VsyncSource** object lives in **gfxPlatform** and is instantited only on the parent process when **gfxPlatform** is created.
The **VsyncSource** is destroyed when **gfxPlatform** is destroyed.
There is only one **VsyncSource** object throughout the entire lifetime of Firefox.
Each platform is expected to implement their own **VsyncSource** to manage vsync events.
On Firefox OS, this is through the **HwcComposer2D**.
On OS X, this is through **CVDisplayLinkRef**.
On Windows, it should be through **WaitForVBlank**.

###Multiple Displays
The **VsyncSource** should have an API to switch a **CompositorVsyncDispatcher** from one **Display** to another **Display**.
For example, when one window either goes into full screen mode or moves from one connected monitor to another.
When one window moves to another monitor, we expect a platform specific notification to occur.
The detection of when a window enters full screen mode or moves is not covered by Silk itself, but the framework is built to support this use case.
The expected flow is that the OS notification occurs on **nsIWidget**, which retrieves the associated **CompositorVsyncDispatcher**.
The **CompositorVsyncDispatcher** then notifies the **VsyncSource** to switch the correct **Display** the **CompositorVsyncDispatcher** is connected to.
Because the notification works through the **nsIWidget**, the actual switching of the **CompositorVsyncDispatcher** to the correct **Display** should occur on the *Main Thread*.

###CompositorVsyncDispatcher
The **CompositorVsyncDispatcher** executes on the *Hardware Vsync Thread*.
It contains references to the **nsBaseWidget** it is associated with and has a lifetime equal to the **nsBaseWidget**.
The **CompositorVsyncDispatcher** is responsible for notifying the various components that a vsync event has occured.
There can be multiple **CompositorVsyncDispatchers** per **Display**, one **CompositorVsyncDispatcher** per window.
The only responsibility of the **CompositorVsyncDispatcher** is to notify components when a vsync event has occured, and to stop listening to vsync when no components require vsync events.
We require one **CompositorVsyncDispatcher** per window so that we can handle multiple **Displays**.

#Compositor
When the **CompositorVsyncDispatcher** is notified of the vsync event, the **Compositor** associated with the **CompositorVsyncDispatcher** begins execution.
Since the **CompositorVsyncDispatcher** executes on the *Hardware Vsync Thread* and the **Compositor** composites on the *CompositorThread*, the **Compositor** posts a task to the *CompositorThread*.
Thus the **CompositorVsyncDispatcher** notifies the **Compositor**, which then schedules the task on the appropriate thread.
The model where the **CompositorVsyncDispatcher** notifies components on the *Hardware Vsync Thread*, and the component schedules the task on the appropriarate thread is used everywhere.

The **Compositor** listens to vsync events as needed and stops listening to vsync when composites are no longer scheduled or required.
Every **CompositorParent** is associated and tied to one **CompositorVsyncDispatcher**.
Each **CompositorParent** is associated with one widget and is created when a new platform window or **nsBaseWidget** is created.
The **CompositorParent**, **CompositorVsyncDispatcher**, and **nsBaseWidget** all have the same lifetimes, which are created and destroyed together.

#GeckoTouchDispatcher
The **GeckoTouchDispatcher** is a singleton that resamples touch events to smooth out jank while tracking a user's finger.
Because input and composite are linked together, the **CompositorVsyncDispatcher** has a reference to the **GeckoTouchDispatcher** and vice versa.

#Input Events
One large goal of Silk is to align touch events with vsync events.
On Firefox OS, touchscreens often have different touch scan rates than the display refreshes.
A Flame device has a touch refresh rate of 75 HZ, while a Nexus 4 has a touch refresh rate of 100 HZ, while the device's display refresh rate is 60HZ.
When a vsync event occurs, we resample touch events then dispatch the resampled touch event to APZ.
Touch events on Firefox OS occur on a *Touch Input Thread* whereas they are processed by APZ on the *APZ Controller Thread*.
We use [Google Android's touch resampling](http://www.masonchang.com/blog/2014/8/25/androids-touch-resampling-algorithm) algorithm to resample touch events.

Currently, we have a strict ordering between Composites and touch events.
When a touch event occurs on the *Touch Input Thread*, we store the touch event in a queue.
When a vsync event occurs, the **CompositorVsyncDispatcher** notifies the **Compositor** of a vsync event.
The **GeckoTouchDispatcher** processes the touch event first, then the **Compositor** finishes compositing.
We require this strict ordering because if a vsync notification is dispatched to both the **Compositor** and **GeckoTouchDispatcher** at the same time, a race condition occurs between processing the touch event and therefore position versus compositing.
In practice, this creates very janky scrolling.
Touch events are processed on the *APZ Controller Thread*, which is the same as the *Compositor Thread* on b2g, which then notifies the **Compositor** to composite with the latest touch input data.
As of this writing, we have not analyzed input events on desktop platforms.

One slight quirk is that input events can start a composite, for example during a scroll and after the **Compositor** is no longer listening to vsync events.
In these cases, we notify the **Compositor** to observe vsync so that it dispatches touch events.
If touch events were not dispatched, and since the **Compositor** is not listening to vsync events, the touch events would never be dispatched.
The **GeckoTouchDispatcher** handles this case by always forcing the **Compositor** to listen to vsync events while touch events are occurring.

###Widget, Compositor, CompositorVsyncDispatcher, GeckoTouchDispatcher Shutdown Procedure
Shutdown Process

When the [nsBaseWidget's destructor runs](http://dxr.mozilla.org/mozilla-central/source/widget/nsBaseWidget.cpp?from=nsBaseWidget.cpp#221) - It calls nsBaseWidget::DestroyCompositor on the *Gecko Main Thread*. The main issue is that we destroy the Compositor through the nsBaseWidget, so the widget will not be kept alive by the nsRefPtr on the CompositorVsyncObserver.

During nsBaseWidget::DestroyCompositor, we first destroy the CompositorChild. This sends a sync IPC call to CompositorParent::RecvStop, which calls [CompositorParent::Destroy](http://dxr.mozilla.org/mozilla-central/source/gfx/layers/ipc/CompositorParent.cpp?from=CompositorParent.cpp#474). During this time, the *main thread* is blocked on the parent process. CompositorParent::Destroy runs on the *Compositor thread* and cleans up some resources, including setting the **CompositorVsyncObserver** to nullptr. CompositorParent::Destroy also explicitly keeps the CompositorParent alive and posts another task to run CompositorParent::DeferredDestroy on the Compositor loop so that all ipdl code can finish executing. The **CompositorVsyncObserver** removes itself as a reference to the **GeckoTouchDispatcher**.

Once CompositorParent::RecvStop finishes, the *main thread* in the parent process continues destroying nsBaseWidget. nsBaseWidget posts another task to [DeferedDestroyCompositor on the main thread](http://dxr.mozilla.org/mozilla-central/source/widget/nsBaseWidget.cpp#168). At the same time, the *Compositor thread* is executing tasks until CompositorParent::DeferredDestroy runs. Now we have a two tasks as both the nsBaseWidget:DeferredDestroyCompositor releases a reference to the Compositor on the *main thread* and the CompositorParent::DeferredDestroy releases a reference to the Compositor on the *compositor thread*. Finally, the CompositorParent itself is destroyed on the *main thread* once both deferred destroy's execute.

With the **CompositorVsyncObserver**, any accesses to the widget after nsBaseWidget::~nsBaseWidget executes are invalid. While the sync call to CompositorParent::RecvStop executes, we set the CompositorVsyncObserver to null. If the CompositorVsyncObserver's vsync notification executes on the *hardware vsync thread*, it will post a task to the Compositor loop and reference an invalid widget. In addition, posting a task to the CompositorLoop would also be invalid as we could destroy the Compositor before the Vsync's tasks executes. Any accesses to the widget between the time the nsBaseWidget's destructor runs and the CompositorVsyncObserver's destructor runs on the *main thread* aren't safe yet a hardware vsync event could occur between these times. Thus, we explicitly shut down vsync events in the **CompositorVsyncDispatcher** during nsBaseWidget destruction.

The **CompositorVsyncDispatcher** may be destroyed on either the *main thread* or *Compositor Thread*, since both the nsBaseWidget and Compositor race to destroy on different threads. Whichever thread finishes destroying last will hold the last reference to the **CompositorVsyncDispatcher**, which destroys the object.

#Refresh Driver
The Refresh Driver is ticked from a [single active timer](http://dxr.mozilla.org/mozilla-central/source/layout/base/nsRefreshDriver.cpp?from=nsRefreshDriver.cpp#11). The assumption is that there are multiple **RefreshDrivers** connected to a single **RefreshTimer**. There are multiple **RefreshTimers**, an active and an inactive **RefreshTimer**. Each Tab has its own **RefreshDriver**, which connects to one of the global **RefreshTimers**. The **RefreshTimers** execute on the *Main Thread* and tick their connected **RefreshDrivers**. We do not want to break this model of multiple **RefreshDrivers** per a limited set of global **RefreshTimers**. Each **RefreshDriver** switches between the active and inactive **RefreshTimer**, which already occurs before Silk.

Instead, we create a new **RefreshTimer**, the **VsyncRefreshTimer** which ticks based on vsync messages. We replace the current active timer with a **VsyncRefreshTimer**. All tabs will then tick based on this new active timer. Since the **RefreshTimer** has a lifetime of the process, we only need to create a single **RefreshTimerVsyncDispatcher** per **Display** when Firefox starts. Even if we do not have any content processes, the Chrome process will still need a **VsyncRefreshTimer**, thus we can associate the **RefreshTimerVsyncDispatcher** with each **Display**.

When Firefox starts, we initially create a new **VsyncRefreshTimer** in the Chrome process. The **VsyncRefreshTimer** will listen to vsync notifications from **RefreshTimerVsyncDispatcher** on the global **Display**. When nsRefreshDriver::Shutdown executes, it will delete the **VsyncRefreshTimer**. This creates a problem as all the **RefreshTimers** are currently manually memory managed whereas **VsyncObservers** are ref counted. To work around this problem, we create a new **VsyncRefreshTimerObserver** as an inner class to **VsyncRefreshTimer**, which actually receives vsync notifications. It then ticks the **RefreshDrivers** inside **VsyncRefreshTimer**.

With Content processes, the start up process is more complicated. We send vsync IPC messages via the use of the PBackground thread on the parent process, which allows us to send messages from the Parent process' without waiting on the *main thread*. This sends messages from the Parent::*PBackground Thread* to the Child::*Main Thread*. The *main thread* receiving IPC messages on the content process is acceptable because **RefreshDrivers** must execute on the *main thread*. However, there is some amount of time required to setup the IPC connection and during this time, the **RefreshDrivers** must tick to set up the process. To get around this, we initially use software **RefreshTimers** that already exist during content process startup and swap in the **VsyncRefreshTimer** once the IPC connection is created.

During nsRefreshDriver::ChooseTimer, we create an async PBackground IPC open request to create a **VsyncParent** and **VsyncChild**. At the same time, we create a software **RefreshTimer** and tick the **RefreshDrivers** as normal. Once the PBackground callback is executed and an IPC connection exists, we swap all **RefreshDrivers** currently associated with the active **RefreshTimer** and swap the **RefreshDrivers** to use the **VsyncRefreshTimer**. Since all interactions on the content process occur on the main thread, there are no need for locks. The **VsyncParent** will listen to vsync events through the **VsyncRefreshTimerDispatcher** on the parent side and send vsync IPC messages to the **VsyncChild**. The **VsyncChild** will then notify the **VsyncRefreshTimer** on the child.

During the shutdown process of the content process, ActorDestroy will be called on the **VsyncChild** and **VsyncParent** due to the normal PBackground shutdown process. Once ActorDestroy is called, no IPC messages should be sent across the channel. After ActorDestroy is called, the IPDL machinery will delete the **VsyncParent/Child** pair. Since the **RefreshTimer** lives as long as the process and is already manually deleted, we don't need to ref count the **VsyncChild**. The **VsyncParent**, due to being a **VsyncObserver**, is ref counted. After **VsyncParent::ActorDestroy** is called, it should unregister itself from the **RefreshTimerVsyncDispatcher**, which should hold the last reference to the **VsyncParent**, and the object will be deleted.

Thus the overall flow during normal execution is:

1. VsyncSource::Display::RefreshTimerVsyncDispatcher receives a Vsync notification from the OS in the parent process.
2. RefreshTimerVsyncDispatcher notifies VsyncRefreshTimer::VsyncRefreshTimerObserver that a vsync occured on the parent process on the hardware vsync thread.
3. RefreshTimerVsyncDispatcher notifies the VsyncParent on the hardware vsync thread that a vsync occured.
4. The VsyncRefreshTimer::VsyncRefreshTimerObserver in the parent process posts a task to the main thread that ticks the refresh drivers.
5. VsyncParent posts a task to the PBackground thread to send a vsync IPC message to VsyncChild.
6. VsyncChild receive a vsync notification on the content process on the main thread and ticks their respective RefreshDrivers.

### Multiple Monitors
In order to have multiple monitor support for the **RefreshDrivers**, we will have multiple active **RefreshTimers**. Each **RefreshTimer** will be associated with a specific **Display** via an id and tick when it's respective **Display** vsync occurs. We will have **N RefreshTimers**, where N is the number of connected displays. Each **RefreshTimer** will still have multiple **RefreshDrivers**. When a tab or window change monitors, the **nsIWidget** will receive a display changed notification. Based on which display the window is on, the window will switch to the correct **RefreshTimerVsyncDispatcher** and **CompositorVsyncDispatcher** on the parent process. Each **TabParent** should also send a notification to their child. Each **TabChild**, given the display ID, switches to the correct **RefreshTimer** associated with the display ID. When each display vsync occurs, it will send one IPC message to notify vsync. The vsync message will contain a display ID, to tick the appropriate **RefreshTimer** on the content process. There will still be only one **VsyncParent/VsyncChild** pair, just each vsync notification will include a display ID, which maps to the correct **RefreshTimer**.

#Object Lifetime
Object lifetime
1. CompositorVsyncDispatcher - Lives as long as the nsBaseWidget associated with the VsyncDispatcher
2. CompositorVsyncObserver - Lives and dies the same time as the CompositorParent.
3. RefreshTimerVsyncDispatcher - As long as the associated display object, which is the lifetime of Firefox.
4. VsyncSource - Lives as long as the gfxPlatform on the chrome process, which is the lifetime of Firefox.
5. VsyncParent/VsyncChild - Lives as long as the content process
6. RefreshTimer - Lives as long as the process

#Threads
All **VsyncObservers** are notified on the *Hardware Vsync Thread*. It is the responsibility of the **VsyncObservers** to post tasks to their respective correct thread. For example, the **CompositorVsyncObserver** will be notified on the *Hardware Vsync Thread*, and post a task to the *Compositor Thread* to do the actual composition.

1. Compositor Thread - Nothing changes
2. Main Thread - PVsyncChild receives IPC messages on the main thread.
3. PBackground Thread - Creates a connection from the PBackground thread on the parent process to the main thread in the content process.
4. Hardware Vsync Thread - Every platform is different, but we always have the concept of a hardware vsync thread. Sometimes this is actually created by the host OS. On Windows, we have to create a separate platform thread that blocks on DwmFlush().
