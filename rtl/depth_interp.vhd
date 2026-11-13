-- E3 depth interpolation (RQ-93)
--
-- Bit-exact with Qogpu_Raster.Interp_Z (numeric contract rule 10), checked
-- against tb/vectors/interp.csv:
--
--   num = E_0*z_2 + E_1*z_0 + E_2*z_1        (edge i is opposite vertex i+2)
--   z   = floor((2*num + area2) / (2*area2))  both operands positive
--
-- The quotient always lies between the vertex depths, so it fits DEPTH_W bits:
-- a DEPTH_W-step restoring divider gives the exact floor. For a covered pixel
-- every E_i is in 0..area2 (they sum to area2).
--
-- Fragments without depth work:
--   kill = 1 and no eot/eof : dropped (accepted, nothing sent)
--   kill = 1 with eot or eof: sent as a marker, z unused
--
-- INTERP = false passes z_0 through in one clock. That is bit-exact only when
-- z_0 = z_1 = z_2 (true for the MVP two-triangle scene), so it is a stand-in
-- for integration, never a verification result.
--
--   IDLE -> MUL0 -> MUL1 -> MUL2 -> ACC -> SETUP -> DIV (DEPTH_W steps) -> OUTPUT -> IDLE
--     \-> OUTPUT (marker, or INTERP = false)
--     \-> IDLE   (killed, no marker: dropped)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.qogpu_pkg.all;
use work.raster_pkg.all;

entity depth_interp is
  generic (
    DEPTH_W : positive := 8;
    INTERP  : boolean  := true
  );
  port (
    clk_i       : in  std_logic;
    rst_n_i     : in  std_logic;
    -- from E1/E2
    in_valid_i  : in  std_logic;
    in_ready_o  : out std_logic;
    in_scan_i   : in  scan_t;
    -- to E4 (port list of mvp_block_diagram.md, plus color for E6)
    out_valid_o : out std_logic;
    out_ready_i : in  std_logic;
    out_px_o    : out fb_x_t;
    out_py_o    : out fb_y_t;
    out_z_o     : out unsigned(DEPTH_W - 1 downto 0);
    out_kill_o  : out std_logic;
    out_eot_o   : out std_logic;
    out_eof_o   : out std_logic;
    out_color_o : out pixel_t
  );
end entity;

architecture rtl of depth_interp is
  constant E_W   : positive := AREA_W - 1;              -- covered E_i is unsigned 50 bits
  constant NUM_W : positive := E_W + DEPTH_W + 2;       -- 60 at D = 8 (contract)
  constant N_W   : positive := NUM_W + 2;               -- 2*num + area2, with room for M * 2**k

  type state_t is (IDLE, MUL0, MUL1, MUL2, ACC, SETUP, DIV, OUTPUT);
  signal state : state_t := IDLE;

  signal f     : scan_t := SCAN_ZERO;                   -- fragment being worked on
  signal prod  : unsigned(NUM_W - 1 downto 0) := (others => '0');  -- registered E_i * z
  signal num   : unsigned(NUM_W - 1 downto 0) := (others => '0');
  signal rem_r : unsigned(N_W - 1 downto 0) := (others => '0');   -- running remainder of N
  signal q     : unsigned(DEPTH_W - 1 downto 0) := (others => '0');
  signal k     : natural range 0 to DEPTH_W - 1 := 0;  -- divider step, MSB first
  signal m     : unsigned(N_W - 1 downto 0);            -- 2 * area2
begin
  m <= shift_left(resize(unsigned(f.area2), N_W), 1);

  in_ready_o  <= '1' when state = IDLE else '0';
  out_valid_o <= '1' when state = OUTPUT else '0';
  out_px_o    <= f.px;
  out_py_o    <= f.py;
  out_z_o     <= q;
  out_kill_o  <= f.kill;
  out_eot_o   <= f.eot;
  out_eof_o   <= f.eof;
  out_color_o <= f.color;

  process (clk_i)
    variable e_op : unsigned(E_W - 1 downto 0);
    variable z_op : unsigned(DEPTH_W - 1 downto 0);
    variable n_v  : unsigned(N_W - 1 downto 0);
    variable th   : unsigned(N_W - 1 downto 0);
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        state <= IDLE;
      else
        case state is
          when IDLE =>
            if in_valid_i = '1' then
              f <= in_scan_i;
              q <= (others => '0');
              if in_scan_i.kill = '1' then
                if in_scan_i.eot = '1' or in_scan_i.eof = '1' then
                  state <= OUTPUT;            -- marker
                end if;                       -- else dropped, stay in IDLE
              elsif not INTERP then
                q     <= in_scan_i.z(0)(DEPTH_W - 1 downto 0);
                state <= OUTPUT;
              else
                for i in 0 to 2 loop
                  assert in_scan_i.e(i) >= 0
                    report "depth_interp: negative E on a covered pixel" severity failure;
                end loop;
                num   <= (others => '0');
                state <= MUL0;
              end if;
            end if;

          when MUL0 | MUL1 | MUL2 =>
            case state is
              when MUL0 =>
                e_op := unsigned(f.e(0)(E_W - 1 downto 0));
                z_op := f.z(2)(DEPTH_W - 1 downto 0);
                state <= MUL1;
              when MUL1 =>
                e_op := unsigned(f.e(1)(E_W - 1 downto 0));
                z_op := f.z(0)(DEPTH_W - 1 downto 0);
                state <= MUL2;
              when others =>
                e_op := unsigned(f.e(2)(E_W - 1 downto 0));
                z_op := f.z(1)(DEPTH_W - 1 downto 0);
                state <= ACC;
            end case;
            prod <= resize(e_op * z_op, NUM_W);
            if state /= MUL0 then
              num <= num + prod;
            end if;

          when ACC =>
            num   <= num + prod;
            state <= SETUP;

          when SETUP =>
            n_v := shift_left(resize(num, N_W), 1) + resize(unsigned(f.area2), N_W);
            assert n_v < shift_left(m, DEPTH_W)
              report "depth_interp: z does not fit DEPTH_W bits (numeric contract rule 7)"
              severity failure;
            rem_r <= n_v;
            k     <= DEPTH_W - 1;
            state <= DIV;

          when DIV =>
            th := shift_left(m, k);
            if rem_r >= th then
              rem_r <= rem_r - th;
              q(k)  <= '1';
            end if;
            if k = 0 then
              state <= OUTPUT;
            else
              k <= k - 1;
            end if;

          when OUTPUT =>
            if out_ready_i = '1' then
              state <= IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;
end architecture;
