/**************************************************************************/
/*  GodotApp.java                                                         */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

// __NAME__: Godot build template 4.7.2.stable
//
// This is Godot's own GodotApp.java from the build template named above, plus onDestroy() below.
// tools/android/build_android.sh copies it over android/build/src/main/java/com/godot/game/ before
// every export and stops when the installed template is a different version: then compare
// Godot's new file with this one, carry the onDestroy() part over and update the line above.

package com.godot.game;

import org.godotengine.godot.Godot;
import org.godotengine.godot.GodotActivity;
import org.godotengine.godot.utils.ProcessPhoenix;

import android.app.ActivityManager;
import android.os.Bundle;
import android.os.Process;
import android.os.SystemClock;
import android.util.Log;

import androidx.activity.EdgeToEdge;
import androidx.core.splashscreen.SplashScreen;

/**
 * Template activity for Godot Android builds.
 * Feel free to extend and modify this class for your custom logic.
 */
public class GodotApp extends GodotActivity {
	private static final String TAG = "__NAME__";
	/** How long to wait for the restarted process to take over before ending this one anyway. */
	private static final long REBIRTH_WAIT_MS = 3000;
	static {
		// .NET libraries.
		if (BuildConfig.FLAVOR.equals("mono")) {
			try {
				Log.v("GODOT", "Loading System.Security.Cryptography.Native.Android library");
				System.loadLibrary("System.Security.Cryptography.Native.Android");
			} catch (UnsatisfiedLinkError e) {
				Log.e("GODOT", "Unable to load System.Security.Cryptography.Native.Android library");
			}
		}
	}

	private final Runnable updateWindowAppearance = () -> {
		Godot godot = getGodot();
		if (godot != null) {
			godot.enableImmersiveMode(godot.isInImmersiveMode(), true);
			godot.enableEdgeToEdge(godot.isInEdgeToEdgeMode(), true);
			godot.setSystemBarsAppearance();
		}
	};

	@Override
	public void onCreate(Bundle savedInstanceState) {
		SplashScreen splashScreen = SplashScreen.installSplashScreen(this);
		EdgeToEdge.enable(this);
		super.onCreate(savedInstanceState);

		Godot godot = getGodot();
		if (godot != null && godot.getDisableGodotSplash()) {
			splashScreen.setKeepOnScreenCondition(() -> godot.getRunStatus() != Godot.RunStatus.STARTED);
		}
	}

	@Override
	public void onResume() {
		super.onResume();
		updateWindowAppearance.run();
	}

	/**
	 * Godot cannot shut its engine down and start it again inside one process, and Android sometimes
	 * destroys this activity while keeping the process: after hours in the background the recent
	 * task is trimmed ("finish-imm:recent-task-trimmed") while the cached process sits frozen. The
	 * destroy is then only delivered when the player taps the icon again - in the same moment the
	 * new activity is being launched into the same process. Godot's onDestroy() tears the engine
	 * down in place, which on a Pixel crashed outright ("pthread_mutex_lock called on a destroyed
	 * mutex", in GodotRenderer.onRenderThreadExiting), and even where it survives it ends by
	 * killing the process, taking the activity the player had just opened with it. Either way the
	 * game vanished on its splash screen and the second tap worked.
	 *
	 * So the process ends here, before that teardown starts - Godot would end it a moment later
	 * anyway, and everything worth keeping was saved when the game was paused. If the player is
	 * opening the game right now, it is started again in a fresh process first.
	 */
	@Override
	public void onDestroy() {
		if (isFinishing() && !isChangingConfigurations()) {
			endProcess();
		}
		super.onDestroy();
	}

	private void endProcess() {
		if (isInForeground()) {
			Log.w(TAG, "Activity destroyed while the game is being opened: restarting in a new process");
			// ProcessPhoenix starts the launch intent from its own process and then kills this one
			ProcessPhoenix.triggerRebirth(this);
			SystemClock.sleep(REBIRTH_WAIT_MS);
		} else {
			Log.w(TAG, "Activity destroyed in the background: ending the process instead of tearing Godot down");
		}
		Process.killProcess(Process.myPid());
	}

	/** True when an activity of this process is on screen or being launched onto it. */
	private static boolean isInForeground() {
		ActivityManager.RunningAppProcessInfo info = new ActivityManager.RunningAppProcessInfo();
		ActivityManager.getMyMemoryState(info);
		return info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND;
	}

	@Override
	public void onGodotMainLoopStarted() {
		super.onGodotMainLoopStarted();
		runOnUiThread(updateWindowAppearance);
	}

	@Override
	public void onGodotForceQuit(Godot instance) {
		if (!BuildConfig.FLAVOR.equals("instrumented")) {
			// For instrumented builds, we disable force-quitting to allow the instrumented tests to complete
			// successfully, otherwise they fail when the process crashes.
			super.onGodotForceQuit(instance);
		}
	}

	@Override
	protected boolean isPiPEnabled() {
		return true;
	}
}
