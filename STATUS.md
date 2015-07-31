
Status
============

Currently, the code in this repository completely implements an initial proposal API for the activity haxelib.  This implementation will, however, execute all defined activities within one actual thread of control at execution time.  That is, the current implementation here is single-threaded.

Here at TiVo we are currently working to complete and improve a newer implementation of the initial proposal API that would provide actual multi-threaded execution support on platforms which are capable of it.

The current top of trunk code here contains a nearly completed multi-threaded implementation as well, but it is not "activated" (see Scheduler.hx:11).  This newer implementation currently requires additional non-blocking system level API which is not yet available from released (or even source built) versions of the Haxe standard library and hxcpp compiler back-end.  We are working to refine, complete and submit these additional APIs so that we may make the multi-threaded implementation here the default.  In the mean time, feel free to peruse the multi-threaded implementation in source form.  :)

If you have questions or comments, feel free to contact us at bji@tivo.com (Bryan Ischo) or kulick@tivo.com (Todd Kulick).
