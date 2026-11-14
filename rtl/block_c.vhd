-- Block C: one vertex lane. Instantiate three lanes for triangle A/B/C.
-- Rotation order is X, then Y, then Z. Each product is independently rounded
-- by fx_mul (signed Q16.16, ties toward +infinity).
-- Requires qogpu_fx_pkg.vhd and fx_mul.vhd compiled before this file.
-- Viewport follows the repository contract: X=(x+1)*160, Y=(1-y)*120.
-- Inputs must be normalized and coefficients must describe a valid rotation.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_fx_pkg.all;

entity vertex_transform is
  generic (
    DEPTH_W : positive range 1 to 16 := 8
  );
  port (
    clk_i   : in std_logic;
    rstn_i  : in std_logic; -- Synchronous active-low reset.

    in_valid_i : in std_logic;
    in_ready_o : out std_logic;
    in_x_i     : in signed(31 downto 0);
    in_y_i     : in signed(31 downto 0);
    in_z_i     : in signed(31 downto 0);
    in_id_i    : in unsigned(31 downto 0);
    in_last_i  : in std_logic;

    cos_x_i : in signed(31 downto 0);
    sin_x_i : in signed(31 downto 0);
    cos_y_i : in signed(31 downto 0);
    sin_y_i : in signed(31 downto 0);
    cos_z_i : in signed(31 downto 0);
    sin_z_i : in signed(31 downto 0);

    out_valid_o : out std_logic;
    out_ready_i : in std_logic;
    out_x_o     : out signed(31 downto 0); -- Screen X, Q16.16.
    out_y_o     : out signed(31 downto 0); -- Screen Y, Q16.16, downwards.
    out_z_o     : out unsigned(DEPTH_W - 1 downto 0);
    out_id_o    : out unsigned(31 downto 0);
    out_last_o  : out std_logic
  );
end entity vertex_transform;

architecture rtl of vertex_transform is
  type state_t is (FLUSH, IDLE, MULTIPLY, COMBINE, MAP_SCREEN, PRESENT);
  signal state : state_t;
  signal flush_left : natural range 0 to 3;
  signal rotation_axis : natural range 0 to 2;
  signal issued : natural range 0 to 4;
  signal received : natural range 0 to 3;

  type values_t is array (natural range <>) of q16_t;
  signal coefficients : values_t(0 to 5); -- Cx,Sx,Cy,Sy,Cz,Sz
  signal products : values_t(0 to 3);
  signal x_r, y_r, z_r : q16_t;
  signal id_r : unsigned(31 downto 0);
  signal last_r : std_logic;
  signal screen_x_r, screen_y_r : q16_t;
  signal screen_z_r : unsigned(DEPTH_W - 1 downto 0);

  signal mul_a, mul_b, mul_y : q16_t;
  signal mul_in_valid, mul_out_valid : std_logic;

  function checked_q16(value : signed) return q16_t is
    variable narrowed : q16_t;
  begin
    narrowed := resize(value, 32);
    assert resize(narrowed, value'length) = value
      report "vertex_transform: rotation sum overflows signed 16.16"
      severity failure;
    return narrowed;
  end function;

  function in_unit_range(value : q16_t) return boolean is
  begin
    return value >= -Q16_ONE and value <= Q16_ONE;
  end function;
begin
  multiplier : entity work.fx_mul
    generic map (FRAC => 16, ROUND => 1)
    port map (
      clk => clk_i, a => mul_a, b => mul_b, in_valid => mul_in_valid,
      y => mul_y, out_valid => mul_out_valid
    );

  -- Reset suppresses transfers immediately; the state/datapath reset is
  -- synchronous. FLUSH drains the multiplier, which has no reset port.
  in_ready_o <= '1' when state = IDLE and rstn_i = '1' else '0';
  out_valid_o <= '1' when state = PRESENT and rstn_i = '1' else '0';
  out_x_o <= screen_x_r;
  out_y_o <= screen_y_r;
  out_z_o <= screen_z_r;
  out_id_o <= id_r;
  out_last_o <= last_r;

  -- Four products per axis, issued on consecutive clock edges.
  -- The multiplier never stalls; received products are always captured.
  process(all)
  begin
    mul_a <= (others => '0');
    mul_b <= (others => '0');
    mul_in_valid <= '0';
    if state = MULTIPLY and issued < 4 and rstn_i = '1' then
      mul_in_valid <= '1';
      case rotation_axis is
        when 0 =>
          case issued is
            when 0 => mul_a <= y_r; mul_b <= coefficients(0);
            when 1 => mul_a <= z_r; mul_b <= coefficients(1);
            when 2 => mul_a <= y_r; mul_b <= coefficients(1);
            when 3 => mul_a <= z_r; mul_b <= coefficients(0);
            when others => null;
          end case;
        when 1 =>
          case issued is
            when 0 => mul_a <= x_r; mul_b <= coefficients(2);
            when 1 => mul_a <= z_r; mul_b <= coefficients(3);
            when 2 => mul_a <= x_r; mul_b <= coefficients(3);
            when 3 => mul_a <= z_r; mul_b <= coefficients(2);
            when others => null;
          end case;
        when 2 =>
          case issued is
            when 0 => mul_a <= x_r; mul_b <= coefficients(4);
            when 1 => mul_a <= y_r; mul_b <= coefficients(5);
            when 2 => mul_a <= x_r; mul_b <= coefficients(5);
            when 3 => mul_a <= y_r; mul_b <= coefficients(4);
            when others => null;
          end case;
      end case;
    end if;
  end process;

  process(clk_i)
    variable difference, total : signed(32 downto 0);
  begin
    if rising_edge(clk_i) then
      if rstn_i = '0' then
        state <= FLUSH;
        flush_left <= 3;
        rotation_axis <= 0;
        issued <= 0;
        received <= 0;
        coefficients <= (others => (others => '0'));
        products <= (others => (others => '0'));
        x_r <= (others => '0');
        y_r <= (others => '0');
        z_r <= (others => '0');
        id_r <= (others => '0');
        last_r <= '0';
        screen_x_r <= (others => '0');
        screen_y_r <= (others => '0');
        screen_z_r <= (others => '0');
      else
        case state is
          when FLUSH =>
            if flush_left = 1 then
              flush_left <= 0;
              state <= IDLE;
            else
              flush_left <= flush_left - 1;
            end if;

          when IDLE =>
            if in_valid_i = '1' then
              assert in_unit_range(in_x_i) and in_unit_range(in_y_i)
                     and in_unit_range(in_z_i)
                report "vertex_transform: model coordinate outside -1..1"
                severity failure;
              assert in_unit_range(cos_x_i) and in_unit_range(sin_x_i)
                     and in_unit_range(cos_y_i) and in_unit_range(sin_y_i)
                     and in_unit_range(cos_z_i) and in_unit_range(sin_z_i)
                report "vertex_transform: sin/cos outside -1..1"
                severity failure;
              x_r <= in_x_i;
              y_r <= in_y_i;
              z_r <= in_z_i;
              id_r <= in_id_i;
              last_r <= in_last_i;
              coefficients <= (cos_x_i, sin_x_i, cos_y_i, sin_y_i,
                               cos_z_i, sin_z_i);
              rotation_axis <= 0;
              issued <= 0;
              received <= 0;
              state <= MULTIPLY;
            end if;

          when MULTIPLY =>
            if issued < 4 then
              issued <= issued + 1;
            end if;
            if mul_out_valid = '1' then
              products(received) <= mul_y;
              if received = 3 then
                state <= COMBINE;
              else
                received <= received + 1;
              end if;
            end if;

          when COMBINE =>
            if rotation_axis = 1 then
              -- X2 = X1*Cy + Z1*Sy; Z2 = Z1*Cy - X1*Sy.
              total := resize(products(0), 33) + resize(products(1), 33);
              difference := resize(products(3), 33) - resize(products(2), 33);
              x_r <= checked_q16(total);
              z_r <= checked_q16(difference);
            else
              difference := resize(products(0), 33) - resize(products(1), 33);
              total := resize(products(2), 33) + resize(products(3), 33);
              if rotation_axis = 0 then
                -- Y1 = Y*Cx - Z*Sx; Z1 = Y*Sx + Z*Cx; X unchanged.
                y_r <= checked_q16(difference);
                z_r <= checked_q16(total);
              else
                -- X3 = X2*Cz - Y2*Sz; Y3 = X2*Sz + Y2*Cz; Z unchanged.
                x_r <= checked_q16(difference);
                y_r <= checked_q16(total);
              end if;
            end if;
            if rotation_axis = 2 then
              state <= MAP_SCREEN;
            else
              rotation_axis <= rotation_axis + 1;
              issued <= 0;
              received <= 0;
              state <= MULTIPLY;
            end if;

          when MAP_SCREEN =>
            -- Helpers assert the unit coordinate range: no silent clamping.
            screen_x_r <= viewport_x(x_r);
            screen_y_r <= viewport_y(y_r);
            screen_z_r <= depth_map(z_r, DEPTH_W);
            state <= PRESENT;

          when PRESENT =>
            -- Payload and metadata remain stable until the consumer accepts.
            if out_ready_i = '1' then
              state <= IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture rtl;
