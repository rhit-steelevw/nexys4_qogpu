library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity counter is
    port (
        clk_i   : in  std_logic; -- std_logic just means 0,1, or unknown like a signal
        rst_n_i : in  std_logic; -- Active low: '0' means reset.
        en_i    : in  std_logic; -- '1' counts; '0' holds.
        q_o     : out unsigned(7 downto 0)
    );
end entity;

architecture rtl of counter is
    signal count : unsigned(7 downto 0); --8-bit register that stores the number
begin
    q_o <= count;

    process (clk_i, rst_n_i)
    begin
        if rst_n_i = '0' then
            count <= (others => '0'); -- <= means “assign to the signal,” not “less than or equal.” In (others => '0'), it means: “Give every remaining bit the value 00000000.”
        elsif rising_edge(clk_i) then
            if en_i = '1' then
                count <= count + 1;
            end if; -- No assignment means keep the previous count.
        end if;
    end process;
end architecture;
