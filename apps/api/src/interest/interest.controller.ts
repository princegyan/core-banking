import { Body, Controller, Get, Param, Post, Query, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { PermissionsGuard } from '../auth/permissions.guard';
import { RequirePermissions } from '../auth/permissions.decorator';
import { CurrentUser } from '../auth/current-user.decorator';
import type { AuthenticatedUser } from '../auth/types/authenticated-user';
import { InterestService } from './interest.service';
import { RunAccrualDto } from './dto/run-accrual.dto';
import { PostInterestDto } from './dto/post-interest.dto';

@Controller('interest')
@UseGuards(AuthGuard, PermissionsGuard)
export class InterestController {
  constructor(private readonly interestService: InterestService) {}

  @Post('accrue')
  @RequirePermissions('interest.accrue')
  async runAccrual(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: RunAccrualDto,
  ) {
    return this.interestService.runAccrual(user.tenantId, dto);
  }

  @Post('post')
  @RequirePermissions('interest.post')
  async postInterest(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: PostInterestDto,
  ) {
    return this.interestService.postInterest(user.tenantId, user.id, dto);
  }

  @Get('accruals/:accountId')
  @RequirePermissions('interest.read')
  async getAccruals(
    @CurrentUser() user: AuthenticatedUser,
    @Param('accountId') accountId: string,
    @Query('fromDate') fromDate: string,
    @Query('toDate') toDate: string,
  ) {
    return this.interestService.getAccountAccruals(user.tenantId, accountId, fromDate, toDate);
  }

  @Get('batches')
  @RequirePermissions('interest.read')
  async getBatches(@CurrentUser() user: AuthenticatedUser) {
    return this.interestService.getBatches(user.tenantId);
  }
}
