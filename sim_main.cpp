#include <memory>
#include "Vtb_tsetlin_accelerator.h"
#include "verilated.h"

int main(int argc, char** argv) {
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->commandArgs(argc, argv);

    const std::unique_ptr<Vtb_tsetlin_accelerator> top{
        new Vtb_tsetlin_accelerator{contextp.get()}
    };

    while (!contextp->gotFinish()) {
        // Advance time by 1ns per iteration
        contextp->timeInc(1);
        top->eval();

        if (!top->eventsPending()) break;
    }

    top->final();
    return 0;
}