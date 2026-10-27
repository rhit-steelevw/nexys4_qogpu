-- Framebuffer clear engine: fills all 76,800 pixels (320x240) with one color.
-- Write interface matches framebuffer.vhd: we, waddr (17 bits), wdata (8 bits).
--
--   IDLE --start--> RUN (we=1, waddr counts 0..76799, one write per clock)
--   RUN  --last address written--> FINISH (done=1 for exactly one clock) --> IDLE
--
-- * start is only accepted in IDLE; it is ignored while busy or in FINISH.
-- * color is latched when start is accepted, so it may change during the run.
-- * Reset is synchronous, active low.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity clear_engine is
  port (
    clk, rst_n : in  std_logic;
    start      : in  std_logic;
    color      : in  std_logic_vector(7 downto 0);
    busy, done : out std_logic;
    we         : out std_logic;
    waddr      : out unsigned(16 downto 0);
    wdata      : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of clear_engine is
  type state_t is (IDLE, RUN, FINISH);
  signal state   : state_t := IDLE;
  signal cnt     : unsigned(16 downto 0) := (others => '0');
  signal color_r : std_logic_vector(7 downto 0) := (others => '0');
  constant LAST_ADDR : unsigned(16 downto 0) := to_unsigned(76799, 17);
begin
  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        state <= IDLE;
        cnt   <= (others => '0');
      else
        case state is
          when IDLE =>
            if start = '1' then
              color_r <= color;
              cnt     <= (others => '0');
              state   <= RUN;
            end if;
          when RUN =>
            if cnt = LAST_ADDR then
              state <= FINISH;
            else
              cnt <= cnt + 1;
            end if;
          when FINISH =>
            state <= IDLE;
        end case;
      end if;
    end if;
  end process;

  busy  <= '1' when state = RUN    else '0';
  we    <= '1' when state = RUN    else '0';
  done  <= '1' when state = FINISH else '0';
  waddr <= cnt;
  wdata <= color_r;
end architecture;
