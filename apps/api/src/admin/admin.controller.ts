import {
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Patch,
  Post,
  UseGuards,
} from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { PermissionsGuard } from '../auth/permissions.guard';
import { RequirePermissions } from '../auth/permissions.decorator';
import { CurrentUser } from '../auth/current-user.decorator';
import type { AuthenticatedUser } from '../auth/types/authenticated-user';
import { AdminService } from './admin.service';
import { CreateUserDto } from './dto/create-user.dto';
import { UpdateUserDto } from './dto/update-user.dto';
import { SetUserLimitDto } from './dto/set-user-limit.dto';
import { ConfigureApprovalPolicyDto } from './dto/configure-approval-policy.dto';

@Controller('admin')
@UseGuards(AuthGuard, PermissionsGuard)
export class AdminController {
  constructor(private readonly adminService: AdminService) {}

  @Post('users')
  @RequirePermissions('admin.users.manage')
  async createUser(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: CreateUserDto,
  ) {
    return this.adminService.createUser(user.tenantId, user.id, dto);
  }

  @Get('users')
  @RequirePermissions('admin.read')
  async findAllUsers(@CurrentUser() user: AuthenticatedUser) {
    return this.adminService.findAllUsers(user.tenantId);
  }

  @Get('users/:id')
  @RequirePermissions('admin.read')
  async findOneUser(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') id: string,
  ) {
    return this.adminService.findOneUser(user.tenantId, id);
  }

  @Patch('users/:id')
  @RequirePermissions('admin.users.manage')
  async toggleUserActive(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') id: string,
    @Body() dto: UpdateUserDto,
  ) {
    return this.adminService.toggleUserActive(user.tenantId, id, dto.isActive, user.id);
  }

  @Post('users/:id/roles')
  @RequirePermissions('admin.users.manage')
  async assignRole(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') id: string,
    @Body('roleId') roleId: string,
  ) {
    return this.adminService.assignRole(user.tenantId, id, roleId);
  }

  @Delete('users/:id/roles/:roleId')
  @RequirePermissions('admin.users.manage')
  async removeRole(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') id: string,
    @Param('roleId') roleId: string,
  ) {
    return this.adminService.removeRole(user.tenantId, id, roleId);
  }

  @Patch('users/:id/branch')
  @RequirePermissions('admin.users.manage')
  async assignBranch(
    @CurrentUser() user: AuthenticatedUser,
    @Param('id') id: string,
    @Body('branchId') branchId: string,
  ) {
    return this.adminService.assignBranch(user.tenantId, id, branchId);
  }

  @Post('limits')
  @RequirePermissions('admin.limits.manage')
  async setLimit(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: SetUserLimitDto & { userId: string },
  ) {
    return this.adminService.setLimit(user.tenantId, dto.userId, dto);
  }

  @Get('limits/:userId')
  @RequirePermissions('admin.read')
  async getUserLimits(
    @CurrentUser() user: AuthenticatedUser,
    @Param('userId') userId: string,
  ) {
    return this.adminService.getUserLimits(user.tenantId, userId);
  }

  @Post('limits/check')
  @RequirePermissions('admin.limits.manage')
  async checkLimit(
    @CurrentUser() user: AuthenticatedUser,
    @Body() body: { userId: string; limitType: string; amount: number },
  ) {
    return this.adminService.checkLimit(user.tenantId, body.userId, body.limitType, body.amount);
  }

  @Post('approval-policies')
  @RequirePermissions('admin.policies.manage')
  async configurePolicy(
    @CurrentUser() user: AuthenticatedUser,
    @Body() dto: ConfigureApprovalPolicyDto,
  ) {
    return this.adminService.configurePolicy(user.tenantId, dto);
  }

  @Get('approval-policies')
  @RequirePermissions('admin.read')
  async getPolicies(@CurrentUser() user: AuthenticatedUser) {
    return this.adminService.getPolicies(user.tenantId);
  }

  @Post('branch-controls')
  @RequirePermissions('admin.users.manage')
  async setBranchControl(
    @CurrentUser() user: AuthenticatedUser,
    @Body() body: { branchId: string; controlType: string; controlValue: any },
  ) {
    return this.adminService.setBranchControl(
      user.tenantId,
      body.branchId,
      body.controlType,
      body.controlValue,
    );
  }

  @Get('branch-controls/:branchId')
  @RequirePermissions('admin.read')
  async getBranchControls(
    @CurrentUser() user: AuthenticatedUser,
    @Param('branchId') branchId: string,
  ) {
    return this.adminService.getBranchControls(user.tenantId, branchId);
  }
}
