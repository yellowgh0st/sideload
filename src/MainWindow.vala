/*
* Copyright 2019-2022 elementary, Inc. (https://elementary.io)
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public
* License as published by the Free Software Foundation; either
* version 3 of the License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU General Public
* License along with this program; if not, write to the
* Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
* Boston, MA 02110-1301 USA
*
*/

public class Sideload.MainWindow : Gtk.ApplicationWindow {
    public FlatpakFile file { get; construct; }
    private Cancellable? current_cancellable = null;

    private Gtk.Stack stack;
    private MainView main_view;
    private ProgressView progress_view;

    private string? app_name = null;
    private string? app_id = null;

    public MainWindow (Gtk.Application application, FlatpakFile file) {
        Object (
            application: application,
            icon_name: "io.elementary.sideload",
            resizable: false,
            title: _("Install Untrusted App"),
            file: file
        );
    }

    construct {
        var image = new Gtk.Image.from_icon_name ("io.elementary.sideload") {
            pixel_size = 48,
            valign = Gtk.Align.START
        };

        main_view = new MainView ();
        stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT,
            vhomogeneous = false
        };
        stack.add_child (main_view);
        stack.visible_child = main_view;

        var window_handle = new Gtk.WindowHandle () {
            child = stack
        };

        child = window_handle;

        // We need to hide the title area
        var null_title = new Gtk.Grid () {
            visible = false
        };
        set_titlebar (null_title);

        add_css_class ("dialog");
        add_css_class (Granite.STYLE_CLASS_MESSAGE_DIALOG);

        var granite_settings = Granite.Settings.get_default ();
        var gtk_settings = Gtk.Settings.get_default ();

        gtk_settings.gtk_application_prefer_dark_theme = granite_settings.prefers_color_scheme == Granite.Settings.ColorScheme.DARK;

        granite_settings.notify["prefers-color-scheme"].connect (() => {
            gtk_settings.gtk_application_prefer_dark_theme = granite_settings.prefers_color_scheme == Granite.Settings.ColorScheme.DARK;
        });

        GLib.Application.get_default ().shutdown.connect (() => {
            if (current_cancellable != null) {
                current_cancellable.cancel ();
            }
        });

        if (file.size == "0") {
            var error_view = new ErrorView (file.error_code, file.error_message);
            stack.add_child (error_view);
            stack.visible_child = error_view;
            return;
        } else if (file is FlatpakRefFile) {
            progress_view = new ProgressView (ProgressView.ProgressType.REF_INSTALL);
        } else {
            progress_view = new ProgressView (ProgressView.ProgressType.BUNDLE_INSTALL);
            progress_view.status = (_("Installing %s. Unable to estimate time remaining.")).printf (file.size);
        }

        stack.add_child (progress_view);

        main_view.install_request.connect (on_install_button_clicked);
        file.progress_changed.connect (on_progress_changed);
        file.installation_failed.connect (on_install_failed);
        file.installation_succeeded.connect (on_install_succeeded);
        file.details_ready.connect (() => {
            if (file.already_installed) {
                var success_view = new SuccessView (app_name, SuccessView.SuccessType.ALREADY_INSTALLED);

                stack.add_child (success_view);
                stack.visible_child = success_view;
            } else {
                if (file is FlatpakRefFile) {
                    main_view.display_ref_details (file.size, file.extra_remotes_needed);
                } else {
                    main_view.display_bundle_details (file.size, ((FlatpakBundleFile) file).has_remote, file.extra_remotes_needed);
                }
            }
        });

        get_details.begin ();
    }

    private async void get_details () {
        yield file.get_details ();
        app_name = yield file.get_name ();
        app_id = yield file.get_id ();

        if (app_name != null) {
            progress_view.app_name = app_name;
            main_view.app_name = app_name;
        }
    }

    private void on_install_button_clicked () {
        current_cancellable = new Cancellable ();
        file.install.begin (current_cancellable);
        stack.visible_child = progress_view;

        if (file is FlatpakRefFile) {
            Granite.Services.Application.set_progress_visible.begin (true);
        }
    }

    private void on_progress_changed (string description, double progress) {
        progress_view.status = description;
        progress_view.progress = progress;

        Granite.Services.Application.set_progress.begin (progress);
    }

    private void on_install_failed (int error_code, string? error_message) {
        switch (error_code) {
            case Flatpak.Error.ALREADY_INSTALLED:
                var success_view = new SuccessView (app_name, SuccessView.SuccessType.ALREADY_INSTALLED);
                stack.add_child (success_view);
                stack.visible_child = success_view;
                break;

            case Flatpak.Error.ABORTED:
                break;

            default:
                var error_view = new ErrorView (error_code, error_message);
                stack.add_child (error_view);
                stack.visible_child = error_view;

                break;
        }

        if (file is FlatpakRefFile) {
            Granite.Services.Application.set_progress_visible.begin (false);
        }
    }

    private void on_install_succeeded () {
        var success_view = new SuccessView (app_name);

        stack.add_child (success_view);
        stack.visible_child = success_view;

        if (file is FlatpakRefFile) {
            Granite.Services.Application.set_progress_visible.begin (false);
        }

        if (!is_active) {
            var notification = new Notification (_("App installed"));
            if (app_name != null) {
                notification.set_body (_("Installed “%s”").printf (app_name));
            } else {
                notification.set_body (_("The app was installed"));
            }

            var icon = get_application_icon ();
            if (icon != null) {
                notification.set_icon (icon);
            }
            application.send_notification ("installed", notification);
        }
    }

    private GLib.Icon? get_application_icon () {
        var desktop_info = new GLib.DesktopAppInfo (app_id + ".desktop");
        if (desktop_info != null) {
            return desktop_info.get_icon ();
        }
        return null;
    }
}
