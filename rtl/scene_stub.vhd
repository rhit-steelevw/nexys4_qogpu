-- scene_stub.vhd : stands in for Blocks B and C during Integration 2 (RQ-99)
--
-- Takes Block A's frame start handshake and sends the MVP scene on Block C's
-- output interface (docs/architecture/mvp_block_diagram.md, "Block C"), which is
-- tri_setup's input. Replaced by B -> C in RQ-100 with no change to draw_pipeline.
--
-- Scene = rasterizer_tb frame 2, already screen space (16.16):
--   green (40,60) (200,60) (120,210)   z = 64   x"1C"
--   blue  (120,30) (280,30) (200,180)  z = 191  x"03"
-- BLUE_FIRST swaps the send order; last = '1' always goes on the second one sent.
--
--   IDLE (start_ready_o = 1) --start--> SEND0 --out_ready--> SEND1 --out_ready--> IDLE
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;
use work.qogpu_fx_pkg.all;

entity scene_stub is
  generic (
    DEPTH_W    : positive := 8;
    BLUE_FIRST : boolean  := false
  );
  port (
    clk_i   : in  std_logic;
    rst_n_i : in  std_logic;
    -- from Block A (frame_start_valid_o / frame_start_ready_i)
    start_valid_i : in  std_logic;
    start_ready_o : out std_logic;
    -- Block C output interface = tri_setup input
    out_valid_o : out std_logic;
    out_ready_i : in  std_logic;
    out_v0_x_o, out_v0_y_o : out q16_t;
    out_v1_x_o, out_v1_y_o : out q16_t;
    out_v2_x_o, out_v2_y_o : out q16_t;
    out_v0_z_o, out_v1_z_o, out_v2_z_o : out unsigned(DEPTH_W - 1 downto 0);
    out_color_o : out pixel_t;
    out_last_o  : out std_logic
  );
end entity;

architecture rtl of scene_stub is
  type tri_rec_t is record
    x0, y0, x1, y1, x2, y2 : integer;   -- whole pixels
    z     : natural;
    color : pixel_t;
  end record;
  type scene_t is array (0 to 1) of tri_rec_t;

  constant GREEN_TRI : tri_rec_t := (40, 60, 200, 60, 120, 210, 64, x"1C");
  constant BLUE_TRI  : tri_rec_t := (120, 30, 280, 30, 200, 180, 191, x"03");

  function pick_scene(swap : boolean) return scene_t is
  begin
    if swap then return (BLUE_TRI, GREEN_TRI); end if;
    return (GREEN_TRI, BLUE_TRI);
  end function;
  constant SCENE : scene_t := pick_scene(BLUE_FIRST);

  function q(n : integer) return q16_t is
  begin
    return to_signed(n * 65536, 32);
  end function;

  type state_t is (IDLE, SEND0, SEND1);
  signal state : state_t := IDLE;
  signal cur   : tri_rec_t := SCENE(0);   -- init: integer fields start at integer'low otherwise
begin
  start_ready_o <= '1' when state = IDLE else '0';
  out_valid_o   <= '0' when state = IDLE else '1';
  cur           <= SCENE(1) when state = SEND1 else SCENE(0);
  out_last_o    <= '1' when state = SEND1 else '0';

  -- payload is a function of state only, so it is stable while valid and not ready
  out_v0_x_o <= q(cur.x0);  out_v0_y_o <= q(cur.y0);
  out_v1_x_o <= q(cur.x1);  out_v1_y_o <= q(cur.y1);
  out_v2_x_o <= q(cur.x2);  out_v2_y_o <= q(cur.y2);
  out_v0_z_o <= to_unsigned(cur.z, DEPTH_W);
  out_v1_z_o <= to_unsigned(cur.z, DEPTH_W);
  out_v2_z_o <= to_unsigned(cur.z, DEPTH_W);
  out_color_o <= cur.color;

  process (clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        state <= IDLE;
      else
        case state is
          when IDLE =>
            if start_valid_i = '1' then
              state <= SEND0;
            end if;
          when SEND0 =>
            if out_ready_i = '1' then
              state <= SEND1;
            end if;
          when SEND1 =>
            if out_ready_i = '1' then
              state <= IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
