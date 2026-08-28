// Chair occupancy sensor enclosure
// T-Energy S3 + integrated 18650 + Adafruit MPU-6050 + STEMMA QT cable
// Units: millimetres. Export one part at a time with F6 -> Export STL.

part = "assembly"; // "base", "lid", "usb_gauge", or "assembly"
$fn = 48;

wall = 2.4;
floor_t = 2.4;
base_h = 34.0;
lid_t = 2.4;
lip_h = 3.2;
lip_t = 1.6;
fit = 0.35;
corner_r = 4.5;

body_w = 64.0;
body_l = 98.4;

// LILYGO official DXF envelope: approximately 29.0 x 91.2.
board_w = 29.1;
board_l = 91.2;
board_x = 3.5;
board_y = 3.6;
board_z = 24.0;
board_hole_x = [2.1, 26.95];
board_hole_y = [2.0, 89.05];

usb_y = board_y + 12.5;
usb_z = board_z + 1.8;
usb_open_y = 14.0;
usb_open_z = 9.0;
usb_frame_y = 18.5;
usb_frame_z = 13.0;
usb_frame_depth = 3.2;

// Adafruit board outline is 25.4 x 17.78; rotated here for the side bay.
gyro_w = 17.78;
gyro_l = 25.4;
gyro_x = 40.0;
gyro_y = 30.0;
gyro_z = 7.2;
gyro_hole_x = [2.54, 15.24];
gyro_hole_y = [2.54, 22.86];

board_post_r = 3.0;
gyro_post_r = 2.8;
m2_pilot_r = 0.95;

closure_points = [[37.3, 7.0], [59.0, 7.0], [37.3, 91.4], [59.0, 91.4]];
closure_post_r = 3.8;
m3_pilot_r = 1.35;
m3_clear_r = 1.75;

module rounded_prism(w, l, h, r, z = 0) {
    translate([w / 2, l / 2, z])
        linear_extrude(height = h)
            offset(r = r)
                square([w - 2 * r, l - 2 * r], center = true);
}


module post(x, y, top_z, radius) {
    translate([x, y, floor_t]) cylinder(r = radius, h = top_z - floor_t);
}


module base_positive() {
    union() {
        difference() {
            rounded_prism(body_w, body_l, base_h, corner_r);
            translate([wall, wall, floor_t])
                rounded_prism(
                    body_w - 2 * wall,
                    body_l - 2 * wall,
                    base_h - floor_t + 2,
                    max(1.2, corner_r - wall)
                );
        }

        // USB-C strain-bearing collar.
        translate([-usb_frame_depth + 0.3, usb_y - usb_frame_y / 2, usb_z - usb_frame_z / 2])
            cube([usb_frame_depth, usb_frame_y, usb_frame_z]);

        for (dx = board_hole_x)
            for (dy = board_hole_y)
                post(board_x + dx, board_y + dy, board_z, board_post_r);

        for (dx = gyro_hole_x)
            for (dy = gyro_hole_y)
                post(gyro_x + dx, gyro_y + dy, gyro_z, gyro_post_r);

        // Low divider; the 12 mm gap is the STEMMA cable route.
        translate([35.1, wall, floor_t]) cube([1.8, 24.0 - wall, 10]);
        translate([35.1, 36.0, floor_t]) cube([1.8, body_l - wall - 36.0, 10]);

        for (point = closure_points)
            post(point[0], point[1], base_h - 0.4, closure_post_r);

    }
}


module base() {
    difference() {
        base_positive();

        // USB opening: deliberately larger than the metal receptacle so the
        // common moulded cable plug rests against the collar.
        translate([
            -usb_frame_depth - 2,
            usb_y - usb_open_y / 2,
            usb_z - usb_open_z / 2
        ]) cube([wall + usb_frame_depth + 5, usb_open_y, usb_open_z]);

        for (dx = board_hole_x)
            for (dy = board_hole_y)
                translate([board_x + dx, board_y + dy, board_z - 7])
                    cylinder(r = m2_pilot_r, h = 8);

        for (dx = gyro_hole_x)
            for (dy = gyro_hole_y)
                translate([gyro_x + dx, gyro_y + dy, gyro_z - 4])
                    cylinder(r = m2_pilot_r, h = 5);

        for (point = closure_points)
            translate([point[0], point[1], base_h - 9.4])
                cylinder(r = m3_pilot_r, h = 10);

    }
}


module lid(print_ready = true, explode = 0) {
    plate_z = print_ready ? 0 : base_h + explode;
    lip_z = print_ready ? lid_t : base_h - lip_h + explode;
    cavity_w = body_w - 2 * wall;
    cavity_l = body_l - 2 * wall;

    difference() {
        union() {
            rounded_prism(body_w, body_l, lid_t, corner_r, plate_z);
            difference() {
                translate([wall + fit, wall + fit, lip_z])
                    rounded_prism(
                        cavity_w - 2 * fit,
                        cavity_l - 2 * fit,
                        lip_h,
                        max(1.0, corner_r - wall - fit)
                    );
                translate([wall + fit + lip_t, wall + fit + lip_t, lip_z - 0.5])
                    rounded_prism(
                        cavity_w - 2 * fit - 2 * lip_t,
                        cavity_l - 2 * fit - 2 * lip_t,
                        lip_h + 1,
                        max(0.5, corner_r - wall - fit - lip_t)
                    );
            }
        }
        for (point = closure_points)
            translate([point[0], point[1], plate_z - 1])
                cylinder(r = m3_clear_r, h = lid_t + 2);
    }
}


module usb_gauge() {
    difference() {
        translate([usb_frame_y / 2, usb_frame_z / 2, 0])
            linear_extrude(height = 3)
                offset(r = 2)
                    square([usb_frame_y - 4, usb_frame_z - 4], center = true);
        translate([(usb_frame_y - usb_open_y) / 2, (usb_frame_z - usb_open_z) / 2, -1])
            cube([usb_open_y, usb_open_z, 5]);
    }
}


module assembly() {
    color([0.12, 0.48, 0.78, 0.72]) base();
    color([0.30, 0.67, 0.91, 0.65]) lid(false, 16);

    color([0.02, 0.38, 0.15])
        translate([board_x, board_y, board_z])
            rounded_prism(board_w, board_l, 1.6, 2, 0);
    color([0.68, 0.23, 0.08])
        translate([gyro_x, gyro_y, gyro_z])
            rounded_prism(gyro_w, gyro_l, 1.6, 2, 0);
}


if (part == "base") base();
else if (part == "lid") lid();
else if (part == "usb_gauge") usb_gauge();
else assembly();
