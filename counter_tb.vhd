library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity counter_tb is
end entity;

architecture test of counter_tb is
    signal clk   : std_logic := '0'; -- := '0' starts the value off at 0
    signal rst_n : std_logic := '0';
    signal en    : std_logic := '0';
    signal q     : unsigned(7 downto 0);
begin
    dut : entity work.counter -- dut--> device under test
        port map (clk => clk, rst_n => rst_n, en => en, q => q); -- connects counter's ports to tb ports

    stimulus : process -- stimulus will set the input values going into the counter and check results
        variable expected : natural := 0;
    begin
        -- Check reset before any clock edge: its asynchronous, doesnt wait for clock edge.
        wait for 1 ns;
        assert q = to_unsigned(0, 8) --basically == checks if q == unsigned(0,8)
            report "FAIL: initial reset" severity failure;

        --  20 clock cycles, each lasting 10 ns.
        for cycle in 1 to 20 loop
            -- set the input values going into the counter while the clock is low.
            if cycle <= 2 or cycle = 15 then
                rst_n <= '0'; -- Reset at startup and again after counting.
                en <= '0';
            elsif cycle = 8 or cycle = 9 then
                rst_n <= '1'; -- reset is off here since it's active low
                en <= '0';    -- Two cycles must hold the previous count.
            else
                rst_n <= '1';
                en <= '1';
            end if;

            wait for 5 ns; --clock is low
            clk <= '1'; --set clock to high for next wait
            if rst_n = '0' then
                expected := 0;
            elsif en = '1' then
                expected := expected + 1;
            end if;

            -- Let the clocked register and q update before checking them.
            wait for 1 ns; --clock is high
            assert q = to_unsigned(expected, 8)
                report "FAIL: cycle " & integer'image(cycle) &
                       ", expected " & integer'image(expected) &
                       ", got " & integer'image(to_integer(q))
                severity failure;
            wait for 4 ns; --clock is high
            clk <= '0'; --set clock to low again
        end loop;

        report "PASS: all 20 cycles checked (reset, hold, increment)";
        finish(0);
        wait;
    end process;
end architecture;
