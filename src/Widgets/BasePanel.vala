// -*- Mode: vala; indent-tabs-mode: nil; tab-width: 4 -*-
//
//  Copyright (C) 2011-2014 Wingpanel Developers
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.

public abstract class Wingpanel.Widgets.BasePanel : Gtk.Window {
    private enum Struts {
        LEFT,
        RIGHT,
        TOP,
        BOTTOM,
        LEFT_START,
        LEFT_END,
        RIGHT_START,
        RIGHT_END,
        TOP_START,
        TOP_END,
        BOTTOM_START,
        BOTTOM_END,
        N_VALUES
    }

    protected Services.Settings settings { get; private set; }

    private const int SHADOW_SIZE = 4;

    private int panel_height = 0;
    private int panel_x;
    private int panel_y;
    private int panel_width;
    private int panel_displacement = -40;
    private int monitor_num;
    private uint animation_timer = 0;

    private double legible_alpha_value = -1.0;
    private double panel_alpha = 0.0;
    private double panel_current_alpha = 0.0;
    private double initial_panel_alpha;
    private int fade_duration;
    private int64 start_time;
    const int FALLBACK_FADE_DURATION = 150;

    private PanelShadow shadow = new PanelShadow ();
    private Wnck.Screen wnck_screen;

    public BasePanel (Services.Settings settings) {
        this.settings = settings;

        decorated = false;
        resizable = false;
        skip_taskbar_hint = true;
        app_paintable = true;
        set_visual (get_screen ().get_rgba_visual ());
        set_type_hint (Gdk.WindowTypeHint.DOCK);

        panel_resize (false);

        // Update the panel size on screen size or monitor changes
        screen.size_changed.connect (on_monitors_changed);
        screen.monitors_changed.connect (on_monitors_changed);

        destroy.connect (Gtk.main_quit);

        wnck_screen = Wnck.Screen.get_default ();
        wnck_screen.active_workspace_changed.connect (update_panel_alpha);
        wnck_screen.window_opened.connect ((window) => {
            if (window.get_window_type () == Wnck.WindowType.NORMAL) {
                window.state_changed.connect (window_state_changed);
                window.geometry_changed.connect (window_geometry_changed);
                window.workspace_changed.connect (update_panel_alpha);
            }

            update_panel_alpha ();
        });

        wnck_screen.window_closed.connect ((window) => {
            if (window.get_window_type () == Wnck.WindowType.NORMAL) {
                window.state_changed.disconnect (window_state_changed);
                window.geometry_changed.disconnect (window_geometry_changed);
                window.workspace_changed.disconnect (update_panel_alpha);
            }

            update_panel_alpha ();
        });

        var gala_settings = new Settings ("org.pantheon.desktop.gala.animations");
        gala_settings.changed["enable-animations"].connect(get_fade_duration);
        gala_settings.changed["snap-duration"].connect(get_fade_duration);

        get_fade_duration ();

        update_panel_alpha ();
    }

    private void get_fade_duration () {
        if ("org.pantheon.desktop.gala.animations" in Settings.list_schemas ()) {
            var gala_settings = new Settings ("org.pantheon.desktop.gala.animations");

            if (gala_settings.get_boolean ("enable-animations"))
                fade_duration = gala_settings.get_int ("snap-duration");
            else
                fade_duration = 0;
        } else {
            fade_duration = FALLBACK_FADE_DURATION;
        }
    }

    private void window_state_changed (Wnck.Window window,
            Wnck.WindowState changed_mask, Wnck.WindowState new_state) {
        if (((changed_mask & Wnck.WindowState.MAXIMIZED_VERTICALLY) != 0
            || (changed_mask & Wnck.WindowState.MINIMIZED) != 0)
            && (window.get_workspace () == wnck_screen.get_active_workspace ()
            || window.is_sticky ()))
            update_panel_alpha ();
    }

    private void window_geometry_changed (Wnck.Window window) {
        if (window.is_maximized_vertically ())
            update_panel_alpha ();
    }

    protected abstract Gtk.StyleContext get_draw_style_context ();

    public override void realize () {
        base.realize ();
        panel_resize (false);
    }

    public override bool draw (Cairo.Context cr) {
        Gtk.Allocation size;
        get_allocation (out size);

        if (panel_height != size.height) {
            panel_height = size.height;
            message ("New Panel Height: %i", size.height);
            shadow.move (panel_x, panel_y + panel_height + panel_displacement);
            set_struts ();
        }

        var ctx = get_draw_style_context ();
        var background_color = ctx.get_background_color (Gtk.StateFlags.NORMAL);
        background_color.alpha = panel_current_alpha;
        Gdk.cairo_set_source_rgba (cr, background_color);
        cr.rectangle (size.x, size.y, size.width, size.height);
        cr.fill ();

        // Slide in
        if (animation_timer == 0) {
            panel_displacement = -panel_height;
            animation_timer = Timeout.add (300 / panel_height, animation_callback);
        }

        var child = get_child ();

        if (child != null)
            propagate_draw (child, cr);

        if (panel_alpha > 1E-3) {
            shadow.show ();
            shadow.show_all ();
        } else
            shadow.hide ();

        return true;
    }

    public void update_opacity (double alpha) {
        legible_alpha_value = alpha;
        update_panel_alpha ();
    }

    private void update_panel_alpha () {
        panel_alpha = settings.background_alpha;
        if (settings.auto_adjust_alpha) {
            if (active_workspace_has_maximized_window ())
                panel_alpha = 1.0;
            else if (legible_alpha_value >= 0)
                panel_alpha = legible_alpha_value;
        }

        if (panel_current_alpha != panel_alpha) {
            initial_panel_alpha = panel_current_alpha;
            start_time = 0;
            add_tick_callback (draw_timeout);
        }            
    }

    private bool draw_timeout (Gtk.Widget widget, Gdk.FrameClock frame_clock) {
        queue_draw ();

        if (fade_duration == 0) {
            panel_current_alpha = panel_alpha;

            return false;
        }

        if (start_time == 0) {
            start_time = frame_clock.get_frame_time ();

            return true;
        }

        if (initial_panel_alpha > panel_alpha) {
            panel_current_alpha = initial_panel_alpha - ((double) (frame_clock.get_frame_time () - start_time) 
            / (fade_duration * 1000)) * (initial_panel_alpha - panel_alpha);
            panel_current_alpha = double.max (panel_current_alpha, panel_alpha);
        } else if (initial_panel_alpha < panel_alpha) {
            panel_current_alpha = initial_panel_alpha + ((double) (frame_clock.get_frame_time () - start_time) 
            / (fade_duration * 1000)) * (panel_alpha - initial_panel_alpha);
            panel_current_alpha = double.min (panel_current_alpha, panel_alpha);
        }

        if (panel_current_alpha != panel_alpha)
            return true;

        return false;
    }

    private bool animation_callback () {
        if (panel_displacement >= 0 )
            return false;

        panel_displacement += 1;
        move (panel_x, panel_y + panel_displacement);
        shadow.move (panel_x, panel_y + panel_height + panel_displacement);
        return true;
    }

    private bool active_workspace_has_maximized_window () {
        var workspace = wnck_screen.get_active_workspace ();
        var monitor_workarea = screen.get_monitor_workarea (monitor_num);
        bool window_left = false, window_right = false;
        
        foreach (var window in wnck_screen.get_windows ()) {
            int window_x, window_y, window_width, window_height;
            window.get_geometry (out window_x, out window_y, out window_width, out window_height);

            if ((window.is_pinned () || window.get_workspace () == workspace)
                && window.is_maximized_vertically () && !window.is_minimized ()
                && window_y == monitor_workarea.y) {
                    if (window_x == monitor_workarea.x
                        && window_width == monitor_workarea.width)
                        return true;
                    else if (window_x == monitor_workarea.x
                        && window_width == monitor_workarea.width / 2)
                        window_left = true;
                    else if (window_x == monitor_workarea.x + monitor_workarea.width / 2
                        && window_width == monitor_workarea.width / 2)
                        window_right = true;

                    if (window_left && window_right)
                        return true;
            }
        }

        return false;
    }

    private void on_monitors_changed () {
        panel_resize (true);
    }

    private void set_struts () {
        if (!get_realized ())
            return;

        // Since uchar is 8 bits in vala but the struts are 32 bits
        // we have to allocate 4 times as much and do bit-masking
        var struts = new ulong[Struts.N_VALUES];

        struts[Struts.TOP] = (panel_height + panel_y) * this.get_scale_factor ();
        struts[Struts.TOP_START] = panel_x;
        struts[Struts.TOP_END] = panel_x + panel_width - 1;

        var first_struts = new ulong[Struts.BOTTOM + 1];
        for (var i = 0; i < first_struts.length; i++)
            first_struts[i] = struts[i];

        unowned X.Display display = Gdk.X11Display.get_xdisplay (get_display ());
        var xid = Gdk.X11Window.get_xid (get_window ());

        display.change_property (xid, display.intern_atom ("_NET_WM_STRUT_PARTIAL", false), X.XA_CARDINAL,
                                 32, X.PropMode.Replace, (uchar[]) struts, struts.length);
        display.change_property (xid, display.intern_atom ("_NET_WM_STRUT", false), X.XA_CARDINAL,
                                 32, X.PropMode.Replace, (uchar[]) first_struts, first_struts.length);
    }

    private void panel_resize (bool redraw) {
        Gdk.Rectangle monitor_dimensions;

        monitor_num = screen.get_primary_monitor ();
        screen.get_monitor_geometry (monitor_num, out monitor_dimensions);

        // if we have multiple monitors, we must check if the panel would be placed inbetween
        // monitors. If that's the case we have to move it to the topmost, or we'll make the
        // upper monitor unusable because of the struts.
        // First check if there are monitors overlapping horizontally and if they are higher
        // our current highest, make this one the new highest and test all again
        if (screen.get_n_monitors () > 1) {
            Gdk.Rectangle dimensions;
            for (var i = 0; i < screen.get_n_monitors (); i++) {
                screen.get_monitor_geometry (i, out dimensions);
                if (((dimensions.x >= monitor_dimensions.x
                    && dimensions.x < monitor_dimensions.x + monitor_dimensions.width)
                    || (dimensions.x + dimensions.width > monitor_dimensions.x
                    && dimensions.x + dimensions.width <= monitor_dimensions.x + monitor_dimensions.width)
                    || (dimensions.x < monitor_dimensions.x
                    && dimensions.x + dimensions.width > monitor_dimensions.x + monitor_dimensions.width))
                    && dimensions.y < monitor_dimensions.y) {
                    warning ("Not placing wingpanel on the primary monitor because of problems" +
                        " with multimonitor setups");
                    monitor_dimensions = dimensions;
                    monitor_num = i;
                    i = 0;
                }
            }
        }

        panel_x = monitor_dimensions.x;
        panel_y = monitor_dimensions.y;
        panel_width = monitor_dimensions.width;

        move (panel_x, panel_y + panel_displacement);
        shadow.move (panel_x, panel_y + panel_height + panel_displacement);

        this.set_size_request (panel_width, -1);
        shadow.set_size_request (panel_width, SHADOW_SIZE);

        set_struts ();

        if (redraw)
            queue_draw ();
    }
}
