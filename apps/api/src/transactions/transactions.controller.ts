import {
  Body,
  Controller,
  Post,
  UseGuards,
} from '@nestjs/common';

import { AuthGuard } from '../auth/auth.guard';
import { PermissionsGuard } from '../auth/permissions.guard';
import { RequirePermissions } from '../auth/permissions.decorator';

import { CurrentUser } from '../auth/current-user.decorator';
import type { AuthenticatedUser } from '../auth/types/authenticated-user';

import { CreateDepositDto } from './dto/create-deposit.dto';
import { CreateWithdrawalDto } from './dto/create-withdrawal.dto';
import { TransactionsService } from './transactions.service';

@Controller()
@UseGuards(
  AuthGuard,
  PermissionsGuard,
)
export class TransactionsController {
  constructor(
    private readonly transactionsService: TransactionsService,
  ) {}

  @Post('deposits')
  @RequirePermissions(
    'transactions.deposit',
  )
  async createDeposit(
    @CurrentUser()
    user: AuthenticatedUser,

    @Body()
    dto: CreateDepositDto,
  ) {
    return this.transactionsService.createDeposit(
      user.tenantId,
      user.id,
      dto,
    );
  }

  @Post('withdrawals')
  @RequirePermissions(
    'transactions.withdraw',
  )
  async createWithdrawal(
    @CurrentUser()
    user: AuthenticatedUser,

    @Body()
    dto: CreateWithdrawalDto,
  ) {
    return this.transactionsService.createWithdrawal(
      user.tenantId,
      user.id,
      dto,
    );
  }
}