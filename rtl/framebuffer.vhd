-- 320x240 RGB332 framebuffer, simple dual-port, single clock.
-- Address = y * 320 + x  (valid range 0 .. 76799)
-- Write port: raster/CPU side. Read port: VGA side, 1-cycle read latency.
-- Same-address read/write in one cycle returns the OLD data (read-first).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity framebuffer is
  port (
    clk   : in  std_logic;
    we    : in  std_logic;
    waddr : in  unsigned(16 downto 0);
    wdata : in  std_logic_vector(7 downto 0);   -- raster/CPU side
    raddr : in  unsigned(16 downto 0);
    rdata : out std_logic_vector(7 downto 0)    -- VGA side, 1-cycle read latency
  );
end entity;

architecture rtl of framebuffer is
  type mem_t is array (0 to 76799) of std_logic_vector(7 downto 0);
  signal mem : mem_t := (others => (others => '0'));  -- black at power-up
  attribute ram_style : string;
  attribute ram_style of mem : signal is "block";
begin
  process (clk)
  begin
    if rising_edge(clk) then
      if we = '1' then
        mem(to_integer(waddr)) <= wdata;
      end if;
      rdata <= mem(to_integer(raddr));  -- registered read -> block RAM
    end if;
  end process;
end architecture;
