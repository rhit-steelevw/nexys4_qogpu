-- triangle_transform.vhd : Block C at triangle level (Integration 3, MVP)
--
-- One triangle from Block B (triangle_fetch) -> three vertex_transform lanes in
-- parallel -> one screen-space triangle to Block D (draw_pipeline). The output
-- port list is exactly scene_stub's, so gpu_top can swap one for the other.
--
-- Join on both sides, so the lanes can never drift apart:
--   input : all three lanes accept the same triangle on the same edge
--   output: the triangle leaves only when all three lanes hold a result,
--           and all three are released on the same edge
-- The joins use lane in_ready_o / out_valid_o combinationally. That is safe
-- ONLY because vertex_transform drives both purely from its state
-- (state = IDLE / PRESENT, plus reset), never from its own inputs. If that
-- ever changes, these joins become combinational loops.
--
-- Lane 0 = vertex A, lane 1 = B, lane 2 = C. last comes from lane 0.
-- Color is the constant BASE_COLOR (MVP: one red; shading happens at E5).
-- Vertex IDs are dropped: Block D does not use them.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;
use work.qogpu_fx_pkg.all;

entity triangle_transform is
  generic (
    DEPTH_W    : positive range 1 to 16 := 8;
    BASE_COLOR : pixel_t := x"E0"               -- RGB332 full red
  );
  port (
    clk_i  : in std_logic;
    rstn_i : in std_logic;
    -- from Block B
    tri_valid_i : in  std_logic;
    tri_ready_o : out std_logic;
    tri_last_i  : in  std_logic;
    vertex_a_id_i, vertex_b_id_i, vertex_c_id_i : in unsigned(31 downto 0);
    vertex_a_x_i, vertex_a_y_i, vertex_a_z_i    : in signed(31 downto 0);
    vertex_b_x_i, vertex_b_y_i, vertex_b_z_i    : in signed(31 downto 0);
    vertex_c_x_i, vertex_c_y_i, vertex_c_z_i    : in signed(31 downto 0);
    -- from Block A (identity for the MVP)
    cos_x_i, sin_x_i, cos_y_i, sin_y_i, cos_z_i, sin_z_i : in signed(31 downto 0);
    -- to Block D: same list as scene_stub
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

architecture rtl of triangle_transform is
  type s32_arr_t is array (0 to 2) of signed(31 downto 0);
  type u32_arr_t is array (0 to 2) of unsigned(31 downto 0);
  type z_arr_t   is array (0 to 2) of unsigned(DEPTH_W - 1 downto 0);

  signal in_x, in_y, in_z     : s32_arr_t;
  signal in_id                : u32_arr_t;
  signal out_x, out_y         : s32_arr_t;
  signal out_z                : z_arr_t;
  signal out_last             : std_logic_vector(0 to 2);
  signal lane_in_valid, lane_in_ready   : std_logic_vector(0 to 2);
  signal lane_out_valid, lane_out_ready : std_logic_vector(0 to 2);
  signal all_in_ready, all_out_valid    : std_logic;
begin
  -- slot -> lane
  in_x  <= (vertex_a_x_i, vertex_b_x_i, vertex_c_x_i);
  in_y  <= (vertex_a_y_i, vertex_b_y_i, vertex_c_y_i);
  in_z  <= (vertex_a_z_i, vertex_b_z_i, vertex_c_z_i);
  in_id <= (vertex_a_id_i, vertex_b_id_i, vertex_c_id_i);

  -- input join
  all_in_ready  <= lane_in_ready(0) and lane_in_ready(1) and lane_in_ready(2);
  lane_in_valid <= (others => tri_valid_i and all_in_ready);
  tri_ready_o   <= all_in_ready;

  -- output join
  all_out_valid  <= lane_out_valid(0) and lane_out_valid(1) and lane_out_valid(2);
  out_valid_o    <= all_out_valid;
  lane_out_ready <= (others => out_ready_i and all_out_valid);

  g_lane : for i in 0 to 2 generate
    u_lane : entity work.vertex_transform
      generic map (DEPTH_W => DEPTH_W)
      port map (
        clk_i => clk_i, rstn_i => rstn_i,
        in_valid_i => lane_in_valid(i), in_ready_o => lane_in_ready(i),
        in_x_i => in_x(i), in_y_i => in_y(i), in_z_i => in_z(i),
        in_id_i => in_id(i), in_last_i => tri_last_i,
        cos_x_i => cos_x_i, sin_x_i => sin_x_i,
        cos_y_i => cos_y_i, sin_y_i => sin_y_i,
        cos_z_i => cos_z_i, sin_z_i => sin_z_i,
        out_valid_o => lane_out_valid(i), out_ready_i => lane_out_ready(i),
        out_x_o => out_x(i), out_y_o => out_y(i), out_z_o => out_z(i),
        out_id_o => open, out_last_o => out_last(i)
      );
  end generate;

  out_v0_x_o <= out_x(0);  out_v0_y_o <= out_y(0);  out_v0_z_o <= out_z(0);
  out_v1_x_o <= out_x(1);  out_v1_y_o <= out_y(1);  out_v1_z_o <= out_z(1);
  out_v2_x_o <= out_x(2);  out_v2_y_o <= out_y(2);  out_v2_z_o <= out_z(2);
  out_last_o  <= out_last(0);
  out_color_o <= BASE_COLOR;

  -- synthesis translate_off
  process (clk_i)
  begin
    if rising_edge(clk_i) then
      assert lane_in_ready = (0 to 2 => lane_in_ready(0))
        report "triangle_transform: lanes out of step (in_ready)" severity failure;
      assert lane_out_valid = (0 to 2 => lane_out_valid(0))
        report "triangle_transform: lanes out of step (out_valid)" severity failure;
    end if;
  end process;
  -- synthesis translate_on
end architecture;
