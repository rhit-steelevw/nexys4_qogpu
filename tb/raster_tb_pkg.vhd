-- raster_tb_pkg: shared helpers for the RQ-93 testbenches
-- Reads one setup.csv row straight into a tri_t, so the E1-E3 benches do not
-- depend on tri_setup (already checked bit-exact by tri_setup_tb).
--
-- Row: tri,x0,y0,z0,x1,y1,z1,x2,y2,z2,A0,B0,A1,B1,A2,B2,area2,TL,xmin,xmax,ymin,ymax,reject
-- Hex widths: x/y 8, z 2, A/B 7, area2 13, TL 1, xmin/xmax 3, ymin/ymax 2.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.qogpu_pkg.all;
use work.raster_pkg.all;

package raster_tb_pkg is
  -- Parse a non-comment setup.csv line; last = '1', color = tri number
  procedure read_setup_row(l : inout line; n : out integer; t : out tri_t);

  -- edge.csv row: tri,px,py,E0,E1,E2,covered (px 3 hex, py 2 hex, E 13 hex)
  procedure read_edge_row(l : inout line; n : out integer; px : out fb_x_t;
                          py : out fb_y_t; e : out e_arr3_t; covered : out std_logic);

  -- interp.csv row: tri,px,py,z (px 3 hex, py 2 hex, z 2 hex)
  procedure read_interp_row(l : inout line; n : out integer; px : out fb_x_t;
                            py : out fb_y_t; z : out unsigned(7 downto 0));

  -- Next line that is not empty and not a comment; false at end of file
  procedure next_data_line(file f : text; l : inout line; ok : out boolean);
end package;

package body raster_tb_pkg is
  procedure read_setup_row(l : inout line; n : out integer; t : out tri_t) is
    variable c    : character;
    variable num  : integer;
    variable x, y : std_logic_vector(31 downto 0);
    variable z    : std_logic_vector(7 downto 0);
    variable ab   : std_logic_vector(27 downto 0);
    variable ar   : std_logic_vector(51 downto 0);
    variable tl   : std_logic_vector(3 downto 0);
    variable x12  : std_logic_vector(11 downto 0);
    variable y8   : std_logic_vector(7 downto 0);
    variable r    : tri_t := TRI_ZERO;
  begin
    read(l, num); read(l, c);
    for i in 0 to 2 loop
      hread(l, x); read(l, c);
      hread(l, y); read(l, c);
      hread(l, z); read(l, c);
      r.vx(i) := signed(x);
      r.vy(i) := signed(y);
      r.z(i)  := resize(unsigned(z), DEPTH_MAX_W);
    end loop;
    for i in 0 to 2 loop
      hread(l, ab); read(l, c);
      r.a(i) := resize(signed(ab), A_W);
      hread(l, ab); read(l, c);
      r.b(i) := resize(signed(ab), B_W);
    end loop;
    hread(l, ar); read(l, c);
    r.area2 := resize(signed(ar), AREA_W);
    hread(l, tl); read(l, c);
    r.tl := tl(2 downto 0);
    hread(l, x12); read(l, c);
    r.xmin := resize(unsigned(x12), FB_X_W);
    hread(l, x12); read(l, c);
    r.xmax := resize(unsigned(x12), FB_X_W);
    hread(l, y8); read(l, c);
    r.ymin := unsigned(y8);
    hread(l, y8); read(l, c);
    r.ymax := unsigned(y8);
    read(l, c);
    if c = '1' then r.empty := '1'; else r.empty := '0'; end if;
    r.last  := '1';
    r.color := std_logic_vector(to_unsigned(num mod 256, 8));
    n := num;
    t := r;
  end procedure;

  procedure read_edge_row(l : inout line; n : out integer; px : out fb_x_t;
                          py : out fb_y_t; e : out e_arr3_t; covered : out std_logic) is
    variable c   : character;
    variable x12 : std_logic_vector(11 downto 0);
    variable y8  : std_logic_vector(7 downto 0);
    variable ev  : std_logic_vector(51 downto 0);
  begin
    read(l, n); read(l, c);
    hread(l, x12); read(l, c); hread(l, y8); read(l, c);
    px := resize(unsigned(x12), FB_X_W);
    py := unsigned(y8);
    for i in 0 to 2 loop
      hread(l, ev); read(l, c);
      e(i) := resize(signed(ev), AREA_W);
    end loop;
    read(l, c);
    if c = '1' then covered := '1'; else covered := '0'; end if;
  end procedure;

  procedure read_interp_row(l : inout line; n : out integer; px : out fb_x_t;
                            py : out fb_y_t; z : out unsigned(7 downto 0)) is
    variable c   : character;
    variable x12 : std_logic_vector(11 downto 0);
    variable y8  : std_logic_vector(7 downto 0);
    variable z8  : std_logic_vector(7 downto 0);
  begin
    read(l, n); read(l, c);
    hread(l, x12); read(l, c); hread(l, y8); read(l, c); hread(l, z8);
    px := resize(unsigned(x12), FB_X_W);
    py := unsigned(y8);
    z  := unsigned(z8);
  end procedure;

  procedure next_data_line(file f : text; l : inout line; ok : out boolean) is
  begin
    ok := false;
    while not endfile(f) loop
      readline(f, l);
      if l'length > 0 and l(l'left) /= '#' then
        ok := true;
        return;
      end if;
    end loop;
  end procedure;
end package body;
