-- E1 pixel scan + E2 coverage (RQ-93)
--
-- Bit-exact with Qogpu_Raster.Edge and Covered (sw/ada/ref/src/qogpu_raster.adb),
-- numeric contract rules 2, 9, 11, 14. Checked against tb/vectors/edge.csv.
--
-- Scans the bounding box row-major (rule 14), one pixel per accepted transfer,
-- and emits EVERY bounding-box pixel with kill = not covered. E3 drops the
-- killed ones (except markers), so this block's output is easy to compare with
-- edge.csv.
--
--   sample point  x_s = px*2^16 + 2^15, y_s = py*2^16 + 2^15         (rule 2)
--   start (once)  E_i = A_i (x_s - x_i) + B_i (y_s - y_i) at (xmin, ymin)
--   step x        E_i += A_i * 2^16
--   step y        Erow_i += B_i * 2^16, then E_i := Erow_i
--   covered       every E_i > 0, or E_i = 0 and TL_i                 (rule 11)
--
-- All steps are exact integer adds, so they match the Ada direct form exactly.
-- E steps only on a transfer (out_valid and out_ready): a stall must not move it.
--
-- empty triangle (D sends it only when last): one marker pixel at (xmin, ymin)
-- with kill = 1, eot = 1, eof = 1, so the frame still finishes.
--
--   IDLE -> DIFF -> MUL -> SUM -> RUN -> IDLE
--     \-> MARK -> IDLE (empty)
-- Reset is synchronous, active low.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;
use work.qogpu_fx_pkg.all;
use work.raster_pkg.all;

entity raster_scan is
  port (
    clk_i       : in  std_logic;
    rst_n_i     : in  std_logic;
    -- from Block D
    in_valid_i  : in  std_logic;
    in_ready_o  : out std_logic;
    in_tri_i    : in  tri_t;
    -- to E3
    out_valid_o : out std_logic;
    out_ready_i : in  std_logic;
    out_scan_o  : out scan_t
  );
end entity;

architecture rtl of raster_scan is
  type state_t is (IDLE, DIFF, MUL, SUM, RUN, MARK);
  signal state : state_t := IDLE;

  signal t : tri_t := TRI_ZERO;          -- triangle being scanned

  type dx_arr3_t is array (0 to 2) of signed(B_W - 1 downto 0);  -- x_s - x_i, 26 bits
  type dy_arr3_t is array (0 to 2) of signed(A_W - 1 downto 0);  -- y_s - y_i, 25 bits
  type p_arr3_t  is array (0 to 2) of signed(A_W + B_W - 1 downto 0);
  signal dx : dx_arr3_t;
  signal dy : dy_arr3_t;
  signal pa, pb : p_arr3_t;              -- A_i * dx_i, B_i * dy_i

  signal px   : fb_x_t := (others => '0');
  signal py   : fb_y_t := (others => '0');
  signal e    : e_arr3_t := (others => (others => '0'));  -- E_i at (px, py)
  signal erow : e_arr3_t := (others => (others => '0'));  -- E_i at (xmin, py)

  signal scan : scan_t := SCAN_ZERO;
  signal cov  : boolean;

  -- pixel index to the Q16 position of its center
  function sample(p : unsigned) return q16_t is
  begin
    return shift_left(signed(resize(p, 32)), FRAC) + 2 ** (FRAC - 1);
  end function;

  -- exact add, asserts the result fits 51 bits (rule 7)
  function add_e(a, b : area_t) return area_t is
    variable r : signed(AREA_W downto 0);
  begin
    r := resize(a, AREA_W + 1) + resize(b, AREA_W + 1);
    assert r(AREA_W) = r(AREA_W - 1)
      report "raster_scan: E does not fit 51 bits (numeric contract rule 7)" severity failure;
    return r(AREA_W - 1 downto 0);
  end function;

  -- rule 11: every E_i > 0, or E_i = 0 on a top-left edge
  function is_covered(e : e_arr3_t; tl : std_logic_vector(2 downto 0)) return boolean is
  begin
    for i in 0 to 2 loop
      if e(i) < 0 or (e(i) = 0 and tl(i) = '0') then
        return false;
      end if;
    end loop;
    return true;
  end function;
begin
  in_ready_o  <= '1' when state = IDLE else '0';
  out_valid_o <= '1' when state = RUN or state = MARK else '0';

  cov <= is_covered(e, t.tl);

  scan.px    <= px;
  scan.py    <= py;
  scan.e     <= e;
  scan.kill  <= '1' when state = MARK or not cov else '0';
  scan.eot   <= '1' when state = MARK or (px = t.xmax and py = t.ymax) else '0';
  scan.eof   <= t.last when state = MARK or (px = t.xmax and py = t.ymax) else '0';
  scan.z     <= t.z;
  scan.area2 <= t.area2;
  scan.color <= t.color;
  out_scan_o <= scan;

  process (clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        state <= IDLE;
      else
        case state is
          when IDLE =>
            if in_valid_i = '1' then
              t  <= in_tri_i;
              px <= in_tri_i.xmin;          -- also the marker position when empty
              py <= in_tri_i.ymin;
              if in_tri_i.empty = '1' then
                state <= MARK;
              else
                state <= DIFF;
              end if;
            end if;

          when DIFF =>
            for i in 0 to 2 loop
              dx(i) <= resize(sample(px) - t.vx(i), B_W);
              dy(i) <= resize(sample(py) - t.vy(i), A_W);
            end loop;
            state <= MUL;

          when MUL =>
            for i in 0 to 2 loop
              pa(i) <= t.a(i) * dx(i);
              pb(i) <= t.b(i) * dy(i);
            end loop;
            state <= SUM;

          when SUM =>
            for i in 0 to 2 loop
              e(i)    <= add_e(pa(i), pb(i));
              erow(i) <= add_e(pa(i), pb(i));
            end loop;
            state <= RUN;

          when RUN =>
            if out_ready_i = '1' then       -- transfer: only now may E step
              if px = t.xmax then
                if py = t.ymax then
                  state <= IDLE;
                else
                  py <= py + 1;
                  px <= t.xmin;
                  for i in 0 to 2 loop
                    erow(i) <= add_e(erow(i), shift_left(resize(t.b(i), AREA_W), FRAC));
                    e(i)    <= add_e(erow(i), shift_left(resize(t.b(i), AREA_W), FRAC));
                  end loop;
                end if;
              else
                px <= px + 1;
                for i in 0 to 2 loop
                  e(i) <= add_e(e(i), shift_left(resize(t.a(i), AREA_W), FRAC));
                end loop;
              end if;
            end if;

          when MARK =>
            if out_ready_i = '1' then
              state <= IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
